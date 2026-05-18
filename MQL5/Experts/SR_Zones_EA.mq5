//+------------------------------------------------------------------+
//|                                                 SR_Zones_EA.mq5 |
//|                       S&R Zone EA with Pyramid Trade Manager     |
//|                           Modes: EA_MODE | SIGNAL_MODE           |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.08"
#property strict

#include <Pyramid\PyramidEngine.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_OPERATION_MODE { EA_MODE = 0, SIGNAL_MODE = 1 };

enum ENUM_STRENGTH_PRESET_EA
{
    SCALP_EA  = 0,
    LOCAL_EA  = 1,
    SWING_EA  = 2,
    MAJOR_EA  = 3,
    CUSTOM_EA = 4
};

//+------------------------------------------------------------------+
//| Structs (mirrored from indicator)                                |
//+------------------------------------------------------------------+
struct SPivot
{
    double price;
    int    bar;
    double vol;
    double wick;
};

struct SZone
{
    double top;
    double bot;
    double center;
    double strength;
    double volSum;
    int    touches;
    int    firstBar;
    int    lastTouch;
    int    diedBar;
    bool   isResistance;
    bool   wasBroken;
    bool   isLiveBreak;
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== Operation ==="
input ENUM_OPERATION_MODE InpMode       = EA_MODE;         // Operation mode
input string              InpMetaID     = "407DBF6E";              // MetaTrader ID (push notifications)

input group "=== Zone Detection ==="
input ENUM_STRENGTH_PRESET_EA InpPreset = SWING_EA;        // Strength preset
input int    InpPivLeft    = 15;    // Left bars
input int    InpPivRight   = 8;     // Right bars
input double InpClusterTol = 0.9;   // Cluster tolerance (x ATR)
input int    InpMinSpacing = 20;    // Min bars between touches
input int    InpPivBuffer  = 80;    // Pivot memory
input int    InpZoneCount  = 6;     // Active zones per side
input int    InpMinTouches = 2;     // Minimum touches (2=more zones, 3=stricter)
input int    InpHistBars   = 1000;  // Bars of history for zone detection

input group "=== Entry Filter ==="
input int    InpSigCooldownBars = 5;     // Bars between signals on same zone
input bool   InpUseVolFilter    = false; // Enable ATR volatility filter (disable for Gold/indices)
input double InpMinAtrPips      = 5;     // Min ATR pips (forex) / points (Gold: ~100)
input double InpMaxAtrPips      = 2000;  // Max ATR pips (forex: ~80) / points (Gold: ~2000)
input int    InpAtrPeriod       = 14;    // ATR period

input group "=== Trade Settings (EA mode) ==="
input ulong  InpMagic      = 202401;  // Magic number
input int    InpSlippage   = 10;      // Slippage (points)
input double InpLotInitial = 0.05;    // Initial lot (largest)
input double InpLotAddon1  = 0.03;    // Add-on 1 lot
input double InpLotAddon2  = 0.02;    // Add-on 2 lot
input double InpSlZoneBuffer = 0.3;   // SL buffer beyond zone edge (x ATR)

input group "=== Pyramid Triggers ==="
input double InpAddon1TrigPips  = 500;  // Add-on 1 trigger (pips) – Gold: 500 = $5
input double InpAddon2TrigPips  = 1000; // Add-on 2 trigger (pips) – Gold: 1000 = $10
input double InpStopAddon1Pips  = 300;  // Stop distance after add-on 1 – Gold: 300 = $3
input double InpStopAddon2Pips  = 150;  // Stop distance after add-on 2 – Gold: 150 = $1.50
input bool   InpTrailAfterFull  = true; // Trail after full pyramid
input double InpTrailPips       = 200;  // Trail distance – Gold: 200 = $2
input double InpTrailStepPips   = 50;   // Trail step – Gold: 50 = $0.50

input group "=== Role Flip Retests ==="
input bool   InpUseRetests       = true;  // Trade/signal role-flip retests
input int    InpRetestWindowBars = 80;    // Max bars after break to accept retest
input double InpRetestSlBuffer   = 0.3;  // SL buffer beyond flipped zone (x ATR)

input group "=== Manual Trade Manager (Signal mode, magic 0) ==="
input bool   InpManageManual    = true;  // Manage manually opened trades
input double InpManualBePips    = 20;    // Move SL to breakeven after (pips)
input double InpManualBeBuffer  = 2;     // Breakeven buffer beyond entry (pips)
input bool   InpManualTrail     = true;  // Enable trailing stop on manual trades
input double InpManualTrailPips = 15;    // Trail distance (pips)
input double InpManualTrailStep = 5;     // Min pips to move trail

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CPyramidEngine  pyramid;
int             atrHandle;
int             pivLeft, pivRight;
double          clusterTol;
int             minSpacing;
datetime        lastBarTime = 0;
datetime        lastSignalTime = 0;

SPivot  highPivots[], lowPivots[];
int     highPivotCount = 0, lowPivotCount = 0;

SZone   resZones[], supZones[];
int     resCount = 0, supCount = 0;

SZone   brokenZones[];
int     brokenCount = 0;
int     lastBreakCheckBar = -1;

// Log throttle: only print zone details when counts change
int     lastLogRes = -1, lastLogSup = -1, lastLogBroken = -1;

// Signal cooldown tracking per zone center
double  sigCenters[];
datetime sigTimes[];
int     sigCoolCount = 0;

//+------------------------------------------------------------------+
//| Utility: safe volume guard                                       |
//+------------------------------------------------------------------+
double SafeVol(long v) { return (v <= 0) ? 1.0 : (double)v; }

double UpperWick(double h, double o, double c) { return h - MathMax(o, c); }
double LowerWick(double l, double o, double c) { return MathMin(o, c) - l; }

//+------------------------------------------------------------------+
bool IsPivotHigh(int b, const double &high[], int total)
{
    if(b < pivLeft || b + pivRight >= total) return false;
    double h = high[b];
    if(h <= 0) return false;
    for(int i = 1; i <= pivLeft;  i++) if(high[b - i] >= h) return false;
    for(int i = 1; i <= pivRight; i++) if(high[b + i] >  h) return false;
    return true;
}

bool IsPivotLow(int b, const double &low[], int total)
{
    if(b < pivLeft || b + pivRight >= total) return false;
    double l = low[b];
    if(l <= 0) return false;
    for(int i = 1; i <= pivLeft;  i++) if(low[b - i] <= l) return false;
    for(int i = 1; i <= pivRight; i++) if(low[b + i] <  l) return false;
    return true;
}

bool IsDuplicatePivot(const SPivot &arr[], int count, int bar)
{
    for(int i = count - 1; i >= 0 && i >= count - 10; i--)
        if(arr[i].bar == bar) return true;
    return false;
}

void AddPivot(SPivot &arr[], int &count, const SPivot &p, int maxCount)
{
    if(count < maxCount)
    {
        if(count >= ArraySize(arr)) ArrayResize(arr, count + 10);
        arr[count++] = p;
    }
    else
    {
        for(int i = 0; i < count - 1; i++) arr[i] = arr[i + 1];
        arr[count - 1] = p;
    }
}

//+------------------------------------------------------------------+
double PivotWeight(SPivot &p, double atr, double vAvg, int currentBar)
{
    double safeVol  = (p.vol  <= 0) ? 0.0 : p.vol;
    double safeWick = (p.wick <  0) ? 0.0 : p.wick;
    int    age      = MathMax(1, currentBar - p.bar);
    double decay    = 1.0 / (1.0 + age / 200.0);
    double volNorm  = (vAvg > 0) ? safeVol / vAvg : 1.0;
    double wickNorm = (atr  > 0) ? safeWick / atr  : 0.0;
    return (1.0 + volNorm * 0.5 + wickNorm * 0.5) * decay;
}

//+------------------------------------------------------------------+
void BuildZones(SPivot &src[], int srcCount, bool isRes, double atr,
                double vAvg, int currentBar, SZone &outZones[], int &outCount)
{
    outCount = 0;
    ArrayResize(outZones, 0);
    if(srcCount < InpMinTouches || atr <= 0) return;

    bool used[];
    ArrayResize(used, srcCount);
    ArrayInitialize(used, false);

    double tol = atr * clusterTol;
    SZone  temp[];
    int    tempCount = 0;
    ArrayResize(temp, srcCount);

    for(int i = 0; i < srcCount; i++)
    {
        if(used[i]) continue;
        int   memberIdx[]; int   memberCount = 0;
        ArrayResize(memberIdx, srcCount);
        memberIdx[memberCount++] = i;
        used[i] = true;

        for(int j = i + 1; j < srcCount; j++)
        {
            if(used[j]) continue;
            if(MathAbs(src[j].price - src[i].price) <= tol)
            {
                bool farEnough = true;
                if(minSpacing > 0)
                    for(int k = 0; k < memberCount && farEnough; k++)
                        if(MathAbs(src[j].bar - src[memberIdx[k]].bar) < minSpacing)
                            farEnough = false;
                if(farEnough) { memberIdx[memberCount++] = j; used[j] = true; }
            }
        }

        if(memberCount >= InpMinTouches)
        {
            double priceSum = 0, weightSum = 0, volSum = 0;
            int earliest = src[memberIdx[0]].bar, latest = src[memberIdx[0]].bar;

            for(int k = 0; k < memberCount; k++)
            {
                SPivot m = src[memberIdx[k]];
                double w = PivotWeight(m, atr, vAvg, currentBar);
                priceSum  += m.price * w;
                weightSum += w;
                volSum    += (m.vol > 0) ? m.vol : 0;
                earliest   = MathMin(earliest, m.bar);
                latest     = MathMax(latest,   m.bar);
            }

            if(weightSum > 0)
            {
                double center = priceSum / weightSum;
                double pad    = atr * 0.25;

                temp[tempCount].top          = center + pad;
                temp[tempCount].bot          = center - pad;
                temp[tempCount].center       = center;
                temp[tempCount].strength     = weightSum;
                temp[tempCount].volSum       = volSum;
                temp[tempCount].touches      = memberCount;
                temp[tempCount].firstBar     = earliest;
                temp[tempCount].lastTouch    = latest;
                temp[tempCount].diedBar      = -1;
                temp[tempCount].isResistance = isRes;
                temp[tempCount].wasBroken    = false;
                temp[tempCount].isLiveBreak  = false;
                tempCount++;
            }
        }
    }

    if(tempCount > 0)
    {
        int keep = MathMin(InpZoneCount, tempCount);
        for(int i = 0; i < keep; i++)
        {
            int bestIdx = i;
            for(int j = i + 1; j < tempCount; j++)
                if(temp[j].strength > temp[bestIdx].strength) bestIdx = j;
            if(bestIdx != i) { SZone tmp = temp[i]; temp[i] = temp[bestIdx]; temp[bestIdx] = tmp; }
        }
        outCount = keep;
        ArrayResize(outZones, keep);
        for(int i = 0; i < keep; i++) outZones[i] = temp[i];
    }
}

//+------------------------------------------------------------------+
//| Archive a zone to the broken list (deduplicates by center+side)  |
//+------------------------------------------------------------------+
void ArchiveBrokenZone(SZone &z, double atr, int breakBar)
{
    double tol = atr * clusterTol * 0.7;
    for(int i = 0; i < brokenCount; i++)
        if(brokenZones[i].isResistance == z.isResistance &&
           MathAbs(brokenZones[i].center - z.center) <= tol)
            return; // already archived

    if(brokenCount >= ArraySize(brokenZones))
        ArrayResize(brokenZones, brokenCount + 10);

    brokenZones[brokenCount]           = z;
    brokenZones[brokenCount].wasBroken = true;
    brokenZones[brokenCount].diedBar   = breakBar;
    brokenCount++;

    // Keep list bounded
    if(brokenCount > 60)
    {
        for(int i = 0; i < brokenCount - 1; i++)
            brokenZones[i] = brokenZones[i + 1];
        brokenCount--;
    }
}

//+------------------------------------------------------------------+
//| Detect fresh zone breaks on the last closed bar                  |
//| Must be called BEFORE zones are rebuilt for this bar             |
//+------------------------------------------------------------------+
void DetectBreaks(double lastClose, double atr, int currentBarIdx)
{
    if(currentBarIdx == lastBreakCheckBar) return;
    lastBreakCheckBar = currentBarIdx;

    // Resistance broken: close above zone top → flips to support
    for(int i = 0; i < resCount; i++)
    {
        if(resZones[i].diedBar >= 0) continue;
        if(lastClose > resZones[i].top)
        {
            resZones[i].diedBar     = currentBarIdx;
            resZones[i].wasBroken   = true;
            resZones[i].isLiveBreak = true;
            ArchiveBrokenZone(resZones[i], atr, currentBarIdx);
        }
    }

    // Support broken: close below zone bot → flips to resistance
    for(int i = 0; i < supCount; i++)
    {
        if(supZones[i].diedBar >= 0) continue;
        if(lastClose < supZones[i].bot)
        {
            supZones[i].diedBar     = currentBarIdx;
            supZones[i].wasBroken   = true;
            supZones[i].isLiveBreak = true;
            ArchiveBrokenZone(supZones[i], atr, currentBarIdx);
        }
    }
}

//+------------------------------------------------------------------+
//| Rebuild zones from current OHLCV history                         |
//+------------------------------------------------------------------+
bool RebuildAllZones()
{
    int barsNeeded = InpHistBars + pivLeft + pivRight + InpAtrPeriod + 10;
    int total      = (int)SeriesInfoInteger(_Symbol, _Period, SERIES_BARS_COUNT);
    if(total < barsNeeded) return false;

    MqlRates rates[];
    ArraySetAsSeries(rates, false);
    int copied = CopyRates(_Symbol, _Period, 0, InpHistBars, rates);
    if(copied <= 0) return false;

    // ATR on the copied window
    double atrBuf[];
    ArrayResize(atrBuf, copied);
    {
        int h = iATR(_Symbol, _Period, 50);
        if(h == INVALID_HANDLE) return false;
        double tmp[];
        ArraySetAsSeries(tmp, false);
        CopyBuffer(h, 0, 0, copied, tmp);
        IndicatorRelease(h);
        for(int i = 0; i < copied; i++) atrBuf[i] = tmp[i];
    }

    // Volume SMA (50)
    double volMa[];
    ArrayResize(volMa, copied);
    {
        double sum = 0;
        for(int i = 0; i < MathMin(50, copied); i++) sum += (double)rates[i].tick_volume;
        volMa[MathMin(49, copied - 1)] = sum / MathMin(50, copied);
        for(int i = 50; i < copied; i++)
        {
            sum += (double)rates[i].tick_volume - (double)rates[i - 50].tick_volume;
            volMa[i] = sum / 50.0;
        }
        double first = volMa[MathMin(49, copied - 1)];
        for(int i = 0; i < MathMin(49, copied); i++) volMa[i] = first;
    }

    highPivotCount = 0;
    lowPivotCount  = 0;
    ArrayResize(highPivots, InpPivBuffer + 10);
    ArrayResize(lowPivots,  InpPivBuffer + 10);

    double h_arr[], l_arr[], o_arr[], c_arr[];
    long   v_arr[];
    ArrayResize(h_arr, copied); ArrayResize(l_arr, copied);
    ArrayResize(o_arr, copied); ArrayResize(c_arr, copied);
    ArrayResize(v_arr, copied);
    for(int i = 0; i < copied; i++)
    {
        h_arr[i] = rates[i].high;  l_arr[i] = rates[i].low;
        o_arr[i] = rates[i].open;  c_arr[i] = rates[i].close;
        v_arr[i] = rates[i].tick_volume;
    }

    for(int bar = pivLeft + pivRight; bar < copied; bar++)
    {
        double atr   = atrBuf[bar];
        double volMaV = volMa[bar];
        if(atr <= 0 || volMaV <= 0) continue;

        int cand = bar - pivRight;
        if(cand < pivLeft) continue;

        if(!IsDuplicatePivot(highPivots, highPivotCount, cand) &&
            IsPivotHigh(cand, h_arr, copied))
        {
            SPivot p;
            p.price = h_arr[cand]; p.bar = cand;
            p.vol   = SafeVol(v_arr[cand]);
            p.wick  = UpperWick(h_arr[cand], o_arr[cand], c_arr[cand]);
            AddPivot(highPivots, highPivotCount, p, InpPivBuffer);
        }

        if(!IsDuplicatePivot(lowPivots, lowPivotCount, cand) &&
            IsPivotLow(cand, l_arr, copied))
        {
            SPivot p;
            p.price = l_arr[cand]; p.bar = cand;
            p.vol   = SafeVol(v_arr[cand]);
            p.wick  = LowerWick(l_arr[cand], o_arr[cand], c_arr[cand]);
            AddPivot(lowPivots, lowPivotCount, p, InpPivBuffer);
        }
    }

    int lastBar = copied - 1;
    double atr  = atrBuf[lastBar];
    double vAvg = volMa[lastBar];

    BuildZones(highPivots, highPivotCount, true,  atr, vAvg, lastBar, resZones, resCount);
    BuildZones(lowPivots,  lowPivotCount,  false, atr, vAvg, lastBar, supZones, supCount);

    return true;
}

//+------------------------------------------------------------------+
//| Signal cooldown                                                  |
//+------------------------------------------------------------------+
bool CooldownOk(double center, double atr)
{
    double tol = atr * clusterTol;
    for(int i = 0; i < sigCoolCount; i++)
        if(MathAbs(sigCenters[i] - center) <= tol)
            if((int)(TimeCurrent() - sigTimes[i]) < InpSigCooldownBars * PeriodSeconds(_Period))
                return false;
    return true;
}

void RecordCooldown(double center)
{
    if(sigCoolCount >= ArraySize(sigCenters))
    {
        ArrayResize(sigCenters, sigCoolCount + 10);
        ArrayResize(sigTimes,   sigCoolCount + 10);
    }
    sigCenters[sigCoolCount] = center;
    sigTimes[sigCoolCount]   = TimeCurrent();
    sigCoolCount++;
    if(sigCoolCount > 50)
    {
        for(int i = 0; i < sigCoolCount - 1; i++)
        {
            sigCenters[i] = sigCenters[i + 1];
            sigTimes[i]   = sigTimes[i + 1];
        }
        sigCoolCount--;
    }
}

//+------------------------------------------------------------------+
//| Find up to 3 nearest zones above or below a price level          |
//| direction=1 → targets above (for buys), direction=-1 → below    |
//+------------------------------------------------------------------+
int FindTpTargets(double fromPrice, int direction, double &tp1, double &tp2, double &tp3)
{
    double candidates[50];
    int    count = 0;

    // Collect centers from opposite side
    if(direction == 1) // targets above → use resistance zone centers
    {
        for(int i = 0; i < resCount; i++)
            if(resZones[i].diedBar < 0 && resZones[i].center > fromPrice)
                if(count < 50) candidates[count++] = resZones[i].center;
        // also include support zones that are above price (broken and acting as resistance)
        for(int i = 0; i < supCount; i++)
            if(supZones[i].diedBar < 0 && supZones[i].center > fromPrice)
                if(count < 50) candidates[count++] = supZones[i].center;
    }
    else // targets below → use support zone centers
    {
        for(int i = 0; i < supCount; i++)
            if(supZones[i].diedBar < 0 && supZones[i].center < fromPrice)
                if(count < 50) candidates[count++] = supZones[i].center;
        for(int i = 0; i < resCount; i++)
            if(resZones[i].diedBar < 0 && resZones[i].center < fromPrice)
                if(count < 50) candidates[count++] = resZones[i].center;
    }

    if(count == 0) return 0;

    // Sort ascending
    for(int i = 0; i < count - 1; i++)
        for(int j = i + 1; j < count; j++)
            if(candidates[j] < candidates[i])
            {
                double tmp = candidates[i];
                candidates[i] = candidates[j];
                candidates[j] = tmp;
            }

    // For buys take lowest 3 above price; for sells take highest 3 below (reverse)
    if(direction == 1)
    {
        tp1 = (count >= 1) ? candidates[0] : 0;
        tp2 = (count >= 2) ? candidates[1] : 0;
        tp3 = (count >= 3) ? candidates[2] : 0;
    }
    else
    {
        tp1 = (count >= 1) ? candidates[count - 1] : 0;
        tp2 = (count >= 2) ? candidates[count - 2] : 0;
        tp3 = (count >= 3) ? candidates[count - 3] : 0;
    }

    return MathMin(count, 3);
}

//+------------------------------------------------------------------+
//| Send push notification helper                                    |
//+------------------------------------------------------------------+
void SendAlert(string msg)
{
    Print(msg);
    if(InpMetaID != "")
        SendNotification(msg);
}

//+------------------------------------------------------------------+
//| Build and send a signal alert string                             |
//+------------------------------------------------------------------+
void SendSignalAlert(string direction, double entry, double sl,
                     double tp1, double tp2, double tp3,
                     string zoneType, double zoneCenter)
{
    string sym = _Symbol;
    int    dg  = _Digits;

    string msg = StringFormat(
        "[%s] %s SIGNAL\n"
        "Zone: %s @ %s\n"
        "Entry: %s\n"
        "SL: %s\n"
        "TP1: %s\n"
        "TP2: %s\n"
        "TP3: %s\n"
        "TF: %s",
        sym, direction,
        zoneType, DoubleToString(zoneCenter, dg),
        DoubleToString(entry, dg),
        DoubleToString(sl, dg),
        tp1 > 0 ? DoubleToString(tp1, dg) : "-",
        tp2 > 0 ? DoubleToString(tp2, dg) : "-",
        tp3 > 0 ? DoubleToString(tp3, dg) : "-",
        EnumToString(_Period)
    );

    SendAlert(msg);
}

//+------------------------------------------------------------------+
//| Send EA trade open notification                                  |
//+------------------------------------------------------------------+
void SendTradeAlert(string direction, double entry, double sl,
                    double tp1, double tp2, double tp3, double lots)
{
    string msg = StringFormat(
        "[%s] TRADE OPENED: %s\n"
        "Lots: %.2f | Entry: %s\n"
        "SL: %s\n"
        "TP1: %s | TP2: %s | TP3: %s",
        _Symbol, direction, lots,
        DoubleToString(entry, _Digits),
        DoubleToString(sl, _Digits),
        tp1 > 0 ? DoubleToString(tp1, _Digits) : "-",
        tp2 > 0 ? DoubleToString(tp2, _Digits) : "-",
        tp3 > 0 ? DoubleToString(tp3, _Digits) : "-"
    );
    SendAlert(msg);
}

//+------------------------------------------------------------------+
//| Check for a support bounce signal on the last closed bar         |
//+------------------------------------------------------------------+
bool CheckBuySignal(double atr, double &outEntry, double &outSL,
                    double &outZoneCenter, string &outZoneType)
{
    double rates_close[], rates_open[], rates_low[], rates_high[];
    ArraySetAsSeries(rates_close, true); ArraySetAsSeries(rates_open, true);
    ArraySetAsSeries(rates_low,   true); ArraySetAsSeries(rates_high, true);
    CopyClose(_Symbol, _Period, 0, 2, rates_close);
    CopyOpen(_Symbol,  _Period, 0, 2, rates_open);
    CopyLow(_Symbol,   _Period, 0, 2, rates_low);
    CopyHigh(_Symbol,  _Period, 0, 2, rates_high);

    // bar 1 = last closed bar
    double o = rates_open[1], h = rates_high[1], l = rates_low[1], c = rates_close[1];

    for(int i = 0; i < supCount; i++)
    {
        if(supZones[i].diedBar >= 0) continue;
        bool pierced = (l <= supZones[i].top);
        bool heldUp  = (c >= supZones[i].bot && c >= o);
        if(pierced && heldUp && CooldownOk(supZones[i].center, atr))
        {
            outEntry      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            outSL         = supZones[i].bot - atr * InpSlZoneBuffer;
            outZoneCenter = supZones[i].center;
            outZoneType   = "Support";
            return true;
        }
    }
    return false;
}

bool CheckSellSignal(double atr, double &outEntry, double &outSL,
                     double &outZoneCenter, string &outZoneType)
{
    double rates_close[], rates_open[], rates_low[], rates_high[];
    ArraySetAsSeries(rates_close, true); ArraySetAsSeries(rates_open, true);
    ArraySetAsSeries(rates_low,   true); ArraySetAsSeries(rates_high, true);
    CopyClose(_Symbol, _Period, 0, 2, rates_close);
    CopyOpen(_Symbol,  _Period, 0, 2, rates_open);
    CopyLow(_Symbol,   _Period, 0, 2, rates_low);
    CopyHigh(_Symbol,  _Period, 0, 2, rates_high);

    double o = rates_open[1], h = rates_high[1], l = rates_low[1], c = rates_close[1];

    for(int i = 0; i < resCount; i++)
    {
        if(resZones[i].diedBar >= 0) continue;
        bool pierced = (h >= resZones[i].bot);
        bool heldDn  = (c <= resZones[i].top && c <= o);
        if(pierced && heldDn && CooldownOk(resZones[i].center, atr))
        {
            outEntry      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            outSL         = resZones[i].top + atr * InpSlZoneBuffer;
            outZoneCenter = resZones[i].center;
            outZoneType   = "Resistance";
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Retest BUY: broken resistance now acts as support                |
//| Price dips back into the flipped zone and closes bullish         |
//+------------------------------------------------------------------+
bool CheckRetestBuy(double atr, double &outEntry, double &outSL,
                    double &outZoneCenter, string &outZoneType, int currentBarIdx)
{
    if(!InpUseRetests) return false;

    double rates_close[], rates_open[], rates_low[], rates_high[];
    ArraySetAsSeries(rates_close, true); ArraySetAsSeries(rates_open, true);
    ArraySetAsSeries(rates_low,   true); ArraySetAsSeries(rates_high, true);
    CopyClose(_Symbol, _Period, 0, 2, rates_close);
    CopyOpen(_Symbol,  _Period, 0, 2, rates_open);
    CopyLow(_Symbol,   _Period, 0, 2, rates_low);
    CopyHigh(_Symbol,  _Period, 0, 2, rates_high);

    double o = rates_open[1], l = rates_low[1], c = rates_close[1];

    for(int i = 0; i < brokenCount; i++)
    {
        SZone z = brokenZones[i];
        if(!z.isResistance || !z.wasBroken || z.diedBar < 0) continue;

        int age = currentBarIdx - z.diedBar;
        if(age <= 0 || age > InpRetestWindowBars)              continue;

        bool dippedIn  = (l <= z.top);
        bool heldAbove = (c >= z.bot && c >= o);

        if(dippedIn && heldAbove && CooldownOk(z.center, atr))
        {
            outEntry      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            outSL         = z.bot - atr * InpRetestSlBuffer;
            outZoneCenter = z.center;
            outZoneType   = "Flipped Support";
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Retest SELL: broken support now acts as resistance               |
//| Price rallies back into the flipped zone and closes bearish      |
//+------------------------------------------------------------------+
bool CheckRetestSell(double atr, double &outEntry, double &outSL,
                     double &outZoneCenter, string &outZoneType, int currentBarIdx)
{
    if(!InpUseRetests) return false;

    double rates_close[], rates_open[], rates_low[], rates_high[];
    ArraySetAsSeries(rates_close, true); ArraySetAsSeries(rates_open, true);
    ArraySetAsSeries(rates_low,   true); ArraySetAsSeries(rates_high, true);
    CopyClose(_Symbol, _Period, 0, 2, rates_close);
    CopyOpen(_Symbol,  _Period, 0, 2, rates_open);
    CopyLow(_Symbol,   _Period, 0, 2, rates_low);
    CopyHigh(_Symbol,  _Period, 0, 2, rates_high);

    double o = rates_open[1], h = rates_high[1], c = rates_close[1];

    for(int i = 0; i < brokenCount; i++)
    {
        SZone z = brokenZones[i];
        if(z.isResistance || !z.wasBroken || z.diedBar < 0) continue;

        int age = currentBarIdx - z.diedBar;
        if(age <= 0 || age > InpRetestWindowBars)             continue;

        bool rallyedIn = (h >= z.bot);
        bool heldBelow = (c <= z.top && c <= o);

        if(rallyedIn && heldBelow && CooldownOk(z.center, atr))
        {
            outEntry      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            outSL         = z.top + atr * InpRetestSlBuffer;
            outZoneCenter = z.center;
            outZoneType   = "Flipped Resistance";
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Manage manually opened trades (magic = 0) on current symbol      |
//| Applies breakeven then trailing stop, every tick                 |
//+------------------------------------------------------------------+
void ManageManualTrades()
{
    if(!InpManageManual) return;

    double pip      = GetPipSize(_Symbol);
    double be_dist  = InpManualBePips    * pip;
    double be_buf   = InpManualBeBuffer  * pip;
    double tr_dist  = InpManualTrailPips * pip;
    double tr_step  = InpManualTrailStep * pip;

    CTrade trade;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket))                            continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)             continue;
        if(PositionGetInteger(POSITION_MAGIC)  != 0)                  continue;
        if(!IsModificationAllowed(_Symbol, ticket))                   continue;

        long   pos_type  = PositionGetInteger(POSITION_TYPE);
        double open_p    = PositionGetDouble(POSITION_PRICE_OPEN);
        double current_sl = PositionGetDouble(POSITION_SL);
        double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        double new_sl = current_sl;

        if(pos_type == POSITION_TYPE_BUY)
        {
            double profit_pips = (bid - open_p) / pip;

            // Phase 1: move to breakeven
            double be_target = open_p + be_buf;
            if(profit_pips >= InpManualBePips && current_sl < be_target)
                new_sl = be_target;

            // Phase 2: trail (only once BE is set)
            if(InpManualTrail && current_sl >= open_p)
            {
                double trail_candidate = bid - tr_dist;
                if(trail_candidate > current_sl + tr_step)
                    new_sl = trail_candidate;
            }

            if(new_sl > current_sl && IsStopLevelValid(_Symbol, new_sl, ORDER_TYPE_BUY))
            {
                new_sl = NormalizeDouble(new_sl, _Digits);
                if(!trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP)))
                    Print("ManageManual: BUY modify failed. Err=", GetLastError());
            }
        }
        else // SELL
        {
            double profit_pips = (open_p - ask) / pip;

            double be_target = open_p - be_buf;
            if(profit_pips >= InpManualBePips && (current_sl == 0 || current_sl > be_target))
                new_sl = be_target;

            if(InpManualTrail && current_sl > 0 && current_sl <= open_p)
            {
                double trail_candidate = ask + tr_dist;
                if(trail_candidate < current_sl - tr_step)
                    new_sl = trail_candidate;
            }

            if(new_sl != current_sl && new_sl > 0 && IsStopLevelValid(_Symbol, new_sl, ORDER_TYPE_SELL))
            {
                new_sl = NormalizeDouble(new_sl, _Digits);
                if(!trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP)))
                    Print("ManageManual: SELL modify failed. Err=", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Is a new bar open?                                               |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime t[];
    ArraySetAsSeries(t, true);
    if(CopyTime(_Symbol, _Period, 0, 1, t) <= 0) return false;
    if(t[0] == lastBarTime) return false;
    lastBarTime = t[0];
    return true;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    switch(InpPreset)
    {
        case SCALP_EA:  pivLeft = 4;           pivRight = 2;            clusterTol = 0.4; minSpacing = 4;            break;
        case LOCAL_EA:  pivLeft = 6;           pivRight = 4;            clusterTol = 0.5; minSpacing = 8;            break;
        case SWING_EA:  pivLeft = InpPivLeft;  pivRight = InpPivRight;  clusterTol = 0.9; minSpacing = 20;           break;
        case MAJOR_EA:  pivLeft = 35;          pivRight = 15;           clusterTol = 1.4; minSpacing = 50;           break;
        case CUSTOM_EA: pivLeft = InpPivLeft;  pivRight = InpPivRight;  clusterTol = InpClusterTol; minSpacing = InpMinSpacing; break;
    }

    atrHandle = iATR(_Symbol, _Period, InpAtrPeriod);
    if(atrHandle == INVALID_HANDLE)
    {
        Print("SR_Zones_EA: Failed to create ATR handle.");
        return INIT_FAILED;
    }

    ArrayResize(sigCenters, 50);
    ArrayResize(sigTimes,   50);
    sigCoolCount = 0;

    ArrayResize(brokenZones, 60);
    brokenCount        = 0;
    lastBreakCheckBar  = -1;

    if(InpMode == EA_MODE)
    {
        if(!pyramid.Init(InpMagic, InpSlippage,
                         InpLotInitial, InpLotAddon1, InpLotAddon2,
                         InpAddon1TrigPips, InpAddon2TrigPips,
                         InpStopAddon1Pips, InpStopAddon2Pips,
                         InpTrailAfterFull, InpTrailPips, InpTrailStepPips))
        {
            Print("SR_Zones_EA: Pyramid engine Init failed.");
            return INIT_FAILED;
        }
        pyramid.RecoverState();
    }

    if(!RebuildAllZones())
        Print("SR_Zones_EA: Initial zone build incomplete – will retry on first bar.");

    Print("SR_Zones_EA: Initialized. Mode=", (InpMode == EA_MODE ? "EA" : "SIGNAL"),
          " Res=", resCount, " Sup=", supCount);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
    // Always manage pyramid on every tick
    if(InpMode == EA_MODE)
        pyramid.Manage();

    // Manage manually opened trades (magic 0) in Signal mode
    if(InpMode == SIGNAL_MODE)
        ManageManualTrades();

    // Signal / entry logic only on new bars
    if(!IsNewBar()) return;

    // Get current ATR before zone detection (needed for DetectBreaks)
    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) <= 0) return;
    double atr = atrBuf[0];
    if(atr <= 0) return;

    // Detect breaks on last closed bar BEFORE rebuilding zones
    double closeBuf[];
    ArraySetAsSeries(closeBuf, true);
    if(CopyClose(_Symbol, _Period, 0, 2, closeBuf) > 0)
    {
        int barIdx = (int)SeriesInfoInteger(_Symbol, _Period, SERIES_BARS_COUNT) - 1;
        DetectBreaks(closeBuf[1], atr, barIdx);
    }

    // Rebuild alive zones
    RebuildAllZones();

    // Only log when zone counts change to avoid spam
    bool zonesChanged = (resCount != lastLogRes || supCount != lastLogSup || brokenCount != lastLogBroken);
    if(zonesChanged)
    {
        lastLogRes    = resCount;
        lastLogSup    = supCount;
        lastLogBroken = brokenCount;

        PrintFormat("SR_Zones_EA: Zones changed | Res=%d Sup=%d Broken=%d ATR=%.5f",
                    resCount, supCount, brokenCount, atr);

        for(int i = 0; i < resCount; i++)
            PrintFormat("  RES[%d] top=%.5f center=%.5f bot=%.5f touches=%d strength=%.2f",
                        i, resZones[i].top, resZones[i].center, resZones[i].bot,
                        resZones[i].touches, resZones[i].strength);

        for(int i = 0; i < supCount; i++)
            PrintFormat("  SUP[%d] top=%.5f center=%.5f bot=%.5f touches=%d strength=%.2f",
                        i, supZones[i].top, supZones[i].center, supZones[i].bot,
                        supZones[i].touches, supZones[i].strength);

        for(int i = 0; i < brokenCount; i++)
            PrintFormat("  BROKEN[%d] %s top=%.5f center=%.5f bot=%.5f",
                        i, brokenZones[i].isResistance ? "RES→SUP" : "SUP→RES",
                        brokenZones[i].top, brokenZones[i].center, brokenZones[i].bot);
    }

    // Volatility filter (disabled by default – enable and tune per instrument)
    if(InpUseVolFilter &&
       !IsVolatilityAcceptable(_Symbol, _Period, InpAtrPeriod, InpMinAtrPips, InpMaxAtrPips))
    {
        double atrPips = atr / GetPipSize(_Symbol);
        PrintFormat("SR_Zones_EA: Volatility filter blocked. ATR=%.1f pips (min=%.1f max=%.1f)",
                    atrPips, InpMinAtrPips, InpMaxAtrPips);
        return;
    }

    if(InpMode == EA_MODE && pyramid.IsActive())
    {
        Print("SR_Zones_EA: Pyramid active – skipping entry check.");
        return;
    }

    double entry = 0, sl = 0, zoneCenter = 0;
    double tp1 = 0, tp2 = 0, tp3 = 0;
    string zoneType = "";

    int barIdx2 = (int)SeriesInfoInteger(_Symbol, _Period, SERIES_BARS_COUNT) - 1;

    // --- Check BUY (support bounce) ---
    if(CheckBuySignal(atr, entry, sl, zoneCenter, zoneType))
    {
        Print("SR_Zones_EA: BUY signal | Zone=", zoneType, " Center=", zoneCenter,
              " Entry=", entry, " SL=", sl);
        FindTpTargets(entry, 1, tp1, tp2, tp3);
        RecordCooldown(zoneCenter);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("BUY", entry, sl, tp1, tp2, tp3, zoneType, zoneCenter);
        else
        {
            if(IsStopLevelValid(_Symbol, sl, ORDER_TYPE_BUY))
            {
                if(!pyramid.OpenInitial(POSITION_TYPE_BUY, entry, sl, InpLotInitial))
                    Print("SR_Zones_EA: BUY OpenInitial returned false.");
                else
                    SendTradeAlert("BUY", entry, sl, tp1, tp2, tp3, InpLotInitial);
            }
            else
                PrintFormat("SR_Zones_EA: BUY SL too close to market. SL=%.5f Ask=%.5f",
                            sl, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
        }
        return;
    }

    // --- Check SELL (resistance reject) ---
    if(CheckSellSignal(atr, entry, sl, zoneCenter, zoneType))
    {
        Print("SR_Zones_EA: SELL signal | Zone=", zoneType, " Center=", zoneCenter,
              " Entry=", entry, " SL=", sl);
        FindTpTargets(entry, -1, tp1, tp2, tp3);
        RecordCooldown(zoneCenter);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("SELL", entry, sl, tp1, tp2, tp3, zoneType, zoneCenter);
        else
        {
            if(IsStopLevelValid(_Symbol, sl, ORDER_TYPE_SELL))
            {
                if(!pyramid.OpenInitial(POSITION_TYPE_SELL, entry, sl, InpLotInitial))
                    Print("SR_Zones_EA: SELL OpenInitial returned false.");
                else
                    SendTradeAlert("SELL", entry, sl, tp1, tp2, tp3, InpLotInitial);
            }
            else
                PrintFormat("SR_Zones_EA: SELL SL too close to market. SL=%.5f Bid=%.5f",
                            sl, SymbolInfoDouble(_Symbol, SYMBOL_BID));
        }
        return;
    }

    // --- Check BUY retest (broken resistance → flipped support) ---
    if(CheckRetestBuy(atr, entry, sl, zoneCenter, zoneType, barIdx2))
    {
        Print("SR_Zones_EA: BUY RETEST signal | Zone=", zoneType, " Center=", zoneCenter,
              " Entry=", entry, " SL=", sl);
        FindTpTargets(entry, 1, tp1, tp2, tp3);
        RecordCooldown(zoneCenter);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("BUY RETEST", entry, sl, tp1, tp2, tp3, zoneType, zoneCenter);
        else
        {
            if(IsStopLevelValid(_Symbol, sl, ORDER_TYPE_BUY))
            {
                if(!pyramid.OpenInitial(POSITION_TYPE_BUY, entry, sl, InpLotInitial))
                    Print("SR_Zones_EA: BUY RETEST OpenInitial returned false.");
                else
                    SendTradeAlert("BUY RETEST", entry, sl, tp1, tp2, tp3, InpLotInitial);
            }
            else
                PrintFormat("SR_Zones_EA: BUY RETEST SL too close. SL=%.5f Ask=%.5f",
                            sl, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
        }
        return;
    }

    // --- Check SELL retest (broken support → flipped resistance) ---
    if(CheckRetestSell(atr, entry, sl, zoneCenter, zoneType, barIdx2))
    {
        Print("SR_Zones_EA: SELL RETEST signal | Zone=", zoneType, " Center=", zoneCenter,
              " Entry=", entry, " SL=", sl);
        FindTpTargets(entry, -1, tp1, tp2, tp3);
        RecordCooldown(zoneCenter);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("SELL RETEST", entry, sl, tp1, tp2, tp3, zoneType, zoneCenter);
        else
        {
            if(IsStopLevelValid(_Symbol, sl, ORDER_TYPE_SELL))
            {
                if(!pyramid.OpenInitial(POSITION_TYPE_SELL, entry, sl, InpLotInitial))
                    Print("SR_Zones_EA: SELL RETEST OpenInitial returned false.");
                else
                    SendTradeAlert("SELL RETEST", entry, sl, tp1, tp2, tp3, InpLotInitial);
            }
            else
                PrintFormat("SR_Zones_EA: SELL RETEST SL too close. SL=%.5f Bid=%.5f",
                            sl, SymbolInfoDouble(_Symbol, SYMBOL_BID));
        }
    }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
    if(InpMode == EA_MODE)
        pyramid.HandleTransaction(trans);
}
