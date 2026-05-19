//+------------------------------------------------------------------+
//|                                                 SR_Zones_EA.mq5 |
//|                       S&R Zone EA with Pyramid Trade Manager     |
//|                           Modes: EA_MODE | SIGNAL_MODE           |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.23"
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

struct SOrderBlock
{
    double bodyHigh;    // max(open, close) of OB candle
    double bodyLow;     // min(open, close) of OB candle
    double wickHigh;    // candle high (for SL reference)
    double wickLow;     // candle low  (for SL reference)
    double mid;         // 50% of body
    bool   isBullOB;    // true = buy signal (last red candle before bull move)
    int    formedBar;   // bar index at formation
    bool   active;      // false = invalidated (price closed through body)
    bool   fromChoch;   // true = formed on CHoCH, false = BOS
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
input string              InpMetaID     = "";              // MetaTrader ID (push notifications) — MUST set your own device ID

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

input group "=== Swing Structure (BOS / CHoCH / Ranging / Manipulation) ==="
input bool   InpUseStructure        = true;  // Use market structure as primary directional filter
input double InpEqualTolerance      = 0.4;   // Equal high/low tolerance (x ATR) – range detection
input bool   InpTradeManipulation   = true;  // Trade wick sweep reversals at range boundaries
input bool   InpDetectChoch         = true;  // Detect CHoCH (early trend flip signal)
input double InpChochDisplacement   = 0.5;   // CHoCH break candle body must be >= X * ATR
input bool   InpChochZoneConfluence = true;  // Require CHoCH swing high/low at known S/R zone

input group "=== Order Blocks ==="
input bool   InpUseOB           = true;  // Detect and trade Order Block retests
input int    InpOBLookback      = 10;    // Bars to scan back for OB candle after BOS/CHoCH
input int    InpMaxOBZones      = 6;     // Max active OBs to track per side
input double InpOBSlBuffer      = 1.0;   // SL buffer beyond OB wick (x ATR)

input group "=== Trend Filter (HTF MA – optional, disabled by default) ==="
input bool             InpUseTrendFilter = false;         // HTF MA filter (structure is primary)
input ENUM_TIMEFRAMES  InpTrendTF        = PERIOD_H1;     // Higher timeframe for trend MA
input int              InpTrendMAPeriod  = 200;           // Trend MA period
input ENUM_MA_METHOD   InpTrendMAMethod  = MODE_EMA;      // Trend MA method
input int              InpTrendMAShift   = 0;             // Trend MA shift

input group "=== Entry Filter ==="
input int    InpSigCooldownBars = 20;    // Bars between signals on same zone (M5: 20 bars = 100 min)
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
input double InpSlZoneBuffer = 1.5;   // SL buffer beyond zone edge (x ATR) – 1.5x gives breathing room

input group "=== Pyramid Triggers ==="
input double InpAddon1TrigPips  = 1500; // Add-on 1 trigger (pips) – Gold: 1500 = $15 sustained move
input double InpAddon2TrigPips  = 2500; // Add-on 2 trigger (pips) – Gold: 2500 = $25
input double InpStopAddon1Pips  = 300;  // SL above entry after add-on 1 – Gold $3 (gap to addon=$12, > broker min)
input double InpStopAddon2Pips  = 1200; // SL above entry after add-on 2 – Gold $12 (must be > addon1 stop)
input bool   InpTrailAfterFull  = true; // Trail after full pyramid
input double InpTrailPips       = 200;  // Trail distance – Gold: 200 = $2
input double InpTrailStepPips   = 50;   // Trail step – Gold: 50 = $0.50

input group "=== Role Flip Retests ==="
input bool   InpUseRetests       = true;  // Trade/signal role-flip retests
input bool   InpRetestOnly       = true;  // Only trade retests (skip raw bounce signals)
input int    InpRetestWindowBars = 80;    // Max bars after break to accept retest
input double InpRetestSlBuffer   = 1.5;  // SL buffer beyond flipped zone (x ATR)

input group "=== Manual Trade Manager (Signal mode, magic 0) ==="
input bool   InpManageManual    = true;  // Manage manually opened trades
input double InpManualBePips    = 20;    // Move SL to breakeven after (pips)
input double InpManualBeBuffer  = 2;     // Breakeven buffer beyond entry (pips)
input bool   InpManualTrail     = true;  // Enable trailing stop on manual trades
input double InpManualTrailPips = 15;    // Trail distance (pips)
input double InpManualTrailStep = 5;     // Min pips to move trail

input group "=== Candle Confluence (zone confirmation) ==="
input bool   InpReqCandle       = true;  // Require at least one candle pattern at zone
input bool   InpUseEngulf       = true;  // Engulfing candle (body fully engulfs prev bar)
input bool   InpUseDoji         = true;  // Doji (body ≤ DojiBodyPct % of candle range)
input double InpDojiBodyPct     = 10.0;  // Doji max body % of total range (default 10%)
input bool   InpUseHammer       = true;  // Hammer / Shooting Star (wick 2x body, small opp wick)
input double InpHammerWickMult  = 2.0;   // Hammer wick must be >= X * body size
input double InpHammerOppWickPct= 30.0;  // Max opposite wick as % of body (default 30%)

input group "=== Stochastic Confluence ==="
input bool            InpUseStoch     = true;         // Require stochastic confirmation at zone
input ENUM_TIMEFRAMES InpStochTF      = PERIOD_M12;   // Stochastic timeframe (M12 recommended)
input int             InpStochK       = 10;           // Stochastic %K period
input int             InpStochD       = 4;            // Stochastic %D period
input int             InpStochSlowing = 3;            // Stochastic slowing
input double          InpStochOB      = 85.0;         // Overbought level – sell zone (85-100)
input double          InpStochOS      = 20.0;         // Oversold level  – buy zone  (0-20)

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CPyramidEngine  pyramid;
int             atrHandle;
int             atrZoneHandle;   // persistent ATR(50) for zone weight calculation
int             trendMAHandle;
int             stochHandle;
int             pivLeft, pivRight;
double          clusterTol;
int             minSpacing;
datetime        lastBarTime = 0;

SPivot  highPivots[], lowPivots[];
int     highPivotCount = 0, lowPivotCount = 0;

SZone   resZones[], supZones[];
int     resCount = 0, supCount = 0;

SZone   brokenZones[];
int     brokenCount = 0;
int     lastBreakCheckBar = -1;

// Log throttle: only print zone details when counts change
int     lastLogRes = -1, lastLogSup = -1, lastLogBroken = -1;
int     lastLogTrend = 0;
int     lastLogStructure = 0;  // throttle structure bias log

// Swing structure state
// +1 = bullish BOS (HH+HL)  -1 = bearish BOS (LH+LL)  0 = ranging/unclear
int     structureBias    = 0;
double  lastBullBOS      = 0;
double  lastBearBOS      = 0;
bool    isRanging        = false;
double  rangeHigh        = 0;
double  rangeLow         = 0;
// Order Blocks
SOrderBlock obZones[];
int         obCount = 0;

// CHoCH tracking
double  lastHL           = 0;   // last confirmed higher low (bullish trend)
double  lastLH           = 0;   // last confirmed lower high (bearish trend)
double  chochLevel       = 0;   // level of last CHoCH for logging
bool    chochActive      = false; // CHoCH detected, waiting for BOS confirmation

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

    // ATR on the copied window — uses persistent atrZoneHandle (created in OnInit, period=50)
    double atrBuf[];
    ArrayResize(atrBuf, copied);
    {
        if(atrZoneHandle == INVALID_HANDLE) return false;
        double tmp[];
        ArraySetAsSeries(tmp, false);
        int got = CopyBuffer(atrZoneHandle, 0, 0, copied, tmp);
        if(got <= 0) return false;
        for(int i = 0; i < got; i++) atrBuf[i] = tmp[i];
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
//| Trend direction: +1 = bullish, -1 = bearish, 0 = filter off     |
//+------------------------------------------------------------------+
int TrendDirection()
{
    if(!InpUseTrendFilter) return 0;

    double maBuf[];
    ArraySetAsSeries(maBuf, true);
    if(CopyBuffer(trendMAHandle, 0, 0, 1, maBuf) <= 0) return 0;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    return (price > maBuf[0]) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Swing structure: BOS, ranging, manipulation                      |
//|  +1 = bullish BOS (HH+HL) → buys only                           |
//|  -1 = bearish BOS (LH+LL) → sells only                          |
//|   0 = ranging (equal HH + equal LL within ATR tolerance)        |
//|       → buy at range low, sell at range high                     |
//+------------------------------------------------------------------+
// Returns true if price is within any zone of the given array
//+------------------------------------------------------------------+
//| Order Block helpers                                              |
//+------------------------------------------------------------------+

// Scan back from bar startBar to find last opposing candle before move
// isBullMove=true → look for last red candle (bearish OB for bull entry)
void FindAndMarkOB(bool isBullMove, int startBar, bool fromChoch)
{
    if(!InpUseOB) return;

    // Resize if needed
    if(obCount >= ArraySize(obZones)) ArrayResize(obZones, obCount + 10);

    int maxLookback = InpOBLookback;
    int barLimit    = (int)Bars(_Symbol, _Period);
    for(int i = startBar; i < startBar + maxLookback && i < barLimit; i++)
    {
        double o = iOpen(_Symbol,  _Period, i);
        double c = iClose(_Symbol, _Period, i);
        double h = iHigh(_Symbol,  _Period, i);
        double l = iLow(_Symbol,   _Period, i);

        bool isBearCandle = (c < o); // red candle
        bool isBullCandle = (c > o); // green candle

        if(isBullMove && isBearCandle)
        {
            SOrderBlock ob;
            ob.bodyHigh  = o;                    // red candle: open is top of body
            ob.bodyLow   = c;                    // close is bottom
            ob.wickHigh  = h;
            ob.wickLow   = l;
            ob.mid       = (o + c) / 2.0;
            ob.isBullOB  = true;
            ob.formedBar = i;
            ob.active    = true;
            ob.fromChoch = fromChoch;

            // Enforce max OBs: remove oldest if at limit
            int bullCount = 0;
            for(int j = 0; j < obCount; j++)
                if(obZones[j].isBullOB && obZones[j].active) bullCount++;
            if(bullCount >= InpMaxOBZones)
            {
                for(int j = 0; j < obCount; j++)
                    if(obZones[j].isBullOB && obZones[j].active)
                        { obZones[j].active = false; break; }
            }

            obZones[obCount++] = ob;
            PrintFormat("SR_Zones_EA: Bullish OB marked | Body=%.2f-%.2f | Bar=%d | %s",
                        ob.bodyLow, ob.bodyHigh, i, fromChoch ? "CHoCH" : "BOS");
            return;
        }
        else if(!isBullMove && isBullCandle)
        {
            SOrderBlock ob;
            ob.bodyHigh  = c;                    // green candle: close is top of body
            ob.bodyLow   = o;                    // open is bottom
            ob.wickHigh  = h;
            ob.wickLow   = l;
            ob.mid       = (o + c) / 2.0;
            ob.isBullOB  = false;
            ob.formedBar = i;
            ob.active    = true;
            ob.fromChoch = fromChoch;

            int bearCount = 0;
            for(int j = 0; j < obCount; j++)
                if(!obZones[j].isBullOB && obZones[j].active) bearCount++;
            if(bearCount >= InpMaxOBZones)
            {
                for(int j = 0; j < obCount; j++)
                    if(!obZones[j].isBullOB && obZones[j].active)
                        { obZones[j].active = false; break; }
            }

            obZones[obCount++] = ob;
            PrintFormat("SR_Zones_EA: Bearish OB marked | Body=%.2f-%.2f | Bar=%d | %s",
                        ob.bodyLow, ob.bodyHigh, i, fromChoch ? "CHoCH" : "BOS");
            return;
        }
    }
}

// Invalidate OBs that price has fully closed through, then compact the array
void InvalidateOBs()
{
    if(!InpUseOB) return;
    double close1 = iClose(_Symbol, _Period, 1);
    for(int i = 0; i < obCount; i++)
    {
        if(!obZones[i].active) continue;
        // Bull OB invalidated if price closes below its body low
        if(obZones[i].isBullOB  && close1 < obZones[i].bodyLow)
            obZones[i].active = false;
        // Bear OB invalidated if price closes above its body high
        if(!obZones[i].isBullOB && close1 > obZones[i].bodyHigh)
            obZones[i].active = false;
    }
    // Compact: shift active entries to front, reclaim slots of dead entries
    int newCount = 0;
    for(int i = 0; i < obCount; i++)
        if(obZones[i].active) obZones[newCount++] = obZones[i];
    obCount = newCount;
}

// Check if bar[1] has returned into a bullish OB — returns best match
bool CheckOBBuySignal(double atr, double &outEntry, double &outSL,
                      double &outCenter, string &outType)
{
    if(!InpUseOB) return false;
    double low1  = iLow(_Symbol,  _Period, 1);
    double close1= iClose(_Symbol,_Period, 1);
    double open1 = iOpen(_Symbol, _Period, 1);
    double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    for(int i = 0; i < obCount; i++)
    {
        SOrderBlock ob = obZones[i];
        if(!ob.active || !ob.isBullOB) continue;
        // Price dipped into OB body, closed bullish above body low
        if(low1 <= ob.bodyHigh && close1 >= ob.bodyLow && close1 >= open1)
        {
            outEntry  = ask;
            outSL     = NormalizeDouble(ob.wickLow - atr * InpOBSlBuffer, _Digits);
            if(outSL >= outEntry) continue; // inverted SL — OB body too tight or ATR too small
            outCenter = ob.mid;
            outType   = ob.fromChoch ? "OB (CHoCH)" : "OB (BOS)";
            return true;
        }
    }
    return false;
}

// Check if bar[1] has returned into a bearish OB
bool CheckOBSellSignal(double atr, double &outEntry, double &outSL,
                       double &outCenter, string &outType)
{
    if(!InpUseOB) return false;
    double high1 = iHigh(_Symbol,  _Period, 1);
    double close1= iClose(_Symbol, _Period, 1);
    double open1 = iOpen(_Symbol,  _Period, 1);
    double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    for(int i = 0; i < obCount; i++)
    {
        SOrderBlock ob = obZones[i];
        if(!ob.active || ob.isBullOB) continue;
        // Price rallied into OB body, closed bearish below body high
        if(high1 >= ob.bodyLow && close1 <= ob.bodyHigh && close1 <= open1)
        {
            outEntry  = bid;
            outSL     = NormalizeDouble(ob.wickHigh + atr * InpOBSlBuffer, _Digits);
            if(outSL <= outEntry) continue; // inverted SL — OB body too tight or ATR too small
            outCenter = ob.mid;
            outType   = ob.fromChoch ? "OB (CHoCH)" : "OB (BOS)";
            return true;
        }
    }
    return false;
}

bool IsAtKnownZone(double price, const SZone &zones[], int count)
{
    for(int i = 0; i < count; i++)
        if(price >= zones[i].bot && price <= zones[i].top) return true;
    return false;
}

// Adds a CHoCH level as a synthetic broken zone for retest tracking
void AddChochZone(double level, double atr, bool wasResistance)
{
    // Dedup: skip if a zone with this center already exists in brokenZones
    double dedup_tol = (atr > 0) ? atr * 0.3 : SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
    for(int i = 0; i < brokenCount; i++)
        if(MathAbs(brokenZones[i].center - level) <= dedup_tol) return;

    if(brokenCount >= ArraySize(brokenZones)) ArrayResize(brokenZones, brokenCount + 10);
    SZone z;
    z.top          = NormalizeDouble(level + atr * 0.3, _Digits);
    z.bot          = NormalizeDouble(level - atr * 0.3, _Digits);
    z.center       = level;
    z.strength     = 2.5;   // CHoCH levels carry high weight
    z.touches      = 1;
    z.isResistance = wasResistance;
    z.wasBroken    = true;
    z.isLiveBreak  = true;
    z.firstBar     = 0;
    z.lastTouch    = 0;
    z.diedBar      = 0;
    z.volSum       = 0;
    brokenZones[brokenCount++] = z;
}

void UpdateStructureBias()
{
    if(!InpUseStructure) { structureBias = 0; isRanging = false; return; }

    if(highPivotCount < 2 || lowPivotCount < 2)
    {
        structureBias = 0; isRanging = false; return;
    }

    int hTop = highPivotCount - 1;
    int lTop = lowPivotCount  - 1;

    double atr = 0;
    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) > 0) atr = atrBuf[0];
    if(atr <= 0) return; // ATR not ready — hold previous state
    double tol = atr * InpEqualTolerance;

    double highDiff = MathAbs(highPivots[hTop].price - highPivots[hTop-1].price);
    double lowDiff  = MathAbs(lowPivots[lTop].price  - lowPivots[lTop-1].price);

    bool higherHigh = (highPivots[hTop].price > highPivots[hTop-1].price + tol);
    bool lowerHigh  = (highPivots[hTop].price < highPivots[hTop-1].price - tol);
    bool equalHigh  = (highDiff <= tol);

    bool higherLow  = (lowPivots[lTop].price  > lowPivots[lTop-1].price  + tol);
    bool lowerLow   = (lowPivots[lTop].price  < lowPivots[lTop-1].price  - tol);
    bool equalLow   = (lowDiff <= tol);

    // Track lastHL and lastLH from confirmed pivots
    if(structureBias == 1 && higherLow)   lastHL = lowPivots[lTop].price;
    if(structureBias == -1 && lowerHigh)  lastLH = highPivots[hTop].price;

    int  prevBias    = structureBias;
    bool prevRanging = isRanging;

    // ── CHoCH detection ───────────────────────────────────────────────
    if(InpDetectChoch)
    {
        double close1  = iClose(_Symbol, _Period, 1);
        double open1   = iOpen(_Symbol,  _Period, 1);
        double body1   = MathAbs(close1 - open1);
        bool   displaced = (atr > 0 && body1 >= atr * InpChochDisplacement);

        // Bearish CHoCH: bullish trend, price closes below last HL
        // Confluence: the swing high that formed LH is at a known resistance zone
        // Guard: do not flip against an active long pyramid — wait for it to close first
        bool pyrLong  = (InpMode == EA_MODE && pyramid.IsActive() &&
                         pyramid.GetState().direction == POSITION_TYPE_BUY);
        bool pyrShort = (InpMode == EA_MODE && pyramid.IsActive() &&
                         pyramid.GetState().direction == POSITION_TYPE_SELL);
        if(!pyrLong && structureBias == 1 && lastHL > 0 && close1 < lastHL && displaced)
        {
            bool zoneConf = !InpChochZoneConfluence ||
                            IsAtKnownZone(highPivots[hTop].price, resZones, resCount);

            if(zoneConf)
            {
                chochLevel  = lastHL;
                chochActive = true;
                AddChochZone(lastHL, atr, false); // lastHL was support, now resistance
                structureBias = -1;
                isRanging     = false;
                lastBearBOS   = lastHL;
                FindAndMarkOB(false, 1, true); // bearish move → look for last green candle
                PrintFormat("SR_Zones_EA: CHoCH BEARISH | Broke HL=%.2f | SwingHigh=%.2f at ResZone=%s",
                            lastHL, highPivots[hTop].price,
                            zoneConf ? "YES" : "NO");
                return;
            }
        }

        // Bullish CHoCH: bearish trend, price closes above last LH
        // Confluence: the swing low that formed HL is at a known support zone
        if(!pyrShort && structureBias == -1 && lastLH > 0 && close1 > lastLH && displaced)
        {
            bool zoneConf = !InpChochZoneConfluence ||
                            IsAtKnownZone(lowPivots[lTop].price, supZones, supCount);

            if(zoneConf)
            {
                chochLevel  = lastLH;
                chochActive = true;
                AddChochZone(lastLH, atr, true); // lastLH was resistance, now support
                structureBias = 1;
                isRanging     = false;
                lastBullBOS   = lastLH;
                FindAndMarkOB(true, 1, true); // bullish move → look for last red candle
                PrintFormat("SR_Zones_EA: CHoCH BULLISH | Broke LH=%.2f | SwingLow=%.2f at SupZone=%s",
                            lastLH, lowPivots[lTop].price,
                            zoneConf ? "YES" : "NO");
                return;
            }
        }
    }
    // ── BOS detection ─────────────────────────────────────────────────
    if(higherHigh && higherLow)
    {
        if(structureBias != 1)
        {
            lastBullBOS = highPivots[hTop].price;
            FindAndMarkOB(true, 1, false); // BOS bull → mark last red candle as bull OB
        }
        structureBias = 1;
        isRanging     = false;
        chochActive   = false;
    }
    else if(lowerHigh && lowerLow)
    {
        if(structureBias != -1)
        {
            lastBearBOS = lowPivots[lTop].price;
            FindAndMarkOB(false, 1, false); // BOS bear → mark last green candle as bear OB
        }
        structureBias = -1;
        isRanging     = false;
        chochActive   = false;
    }
    else if(equalHigh && equalLow)
    {
        rangeHigh     = MathMax(highPivots[hTop].price, highPivots[hTop-1].price);
        rangeLow      = MathMin(lowPivots[lTop].price,  lowPivots[lTop-1].price);
        structureBias = 0;
        isRanging     = true;
        chochActive   = false;
        lastHL        = 0; // reset stale swing references when entering range
        lastLH        = 0;
    }
    // Mixed → hold previous state

    if(structureBias != prevBias || isRanging != prevRanging)
    {
        if(isRanging)
            PrintFormat("SR_Zones_EA: Structure → RANGING | High=%.2f Low=%.2f",
                        rangeHigh, rangeLow);
        else
            PrintFormat("SR_Zones_EA: Structure BOS → %s | Level=%.2f%s",
                        structureBias > 0 ? "BULLISH" : "BEARISH",
                        structureBias > 0 ? lastBullBOS : lastBearBOS,
                        chochActive ? " (CHoCH→BOS confirmed)" : "");
    }
}

//+------------------------------------------------------------------+
//| Manipulation (wick sweep reversal at range boundary)             |
//| Bearish: wick above rangeHigh, close back inside = distribution  |
//| Bullish: wick below rangeLow,  close back inside = accumulation  |
//+------------------------------------------------------------------+
bool IsBullManipulation()
{
    if(!isRanging || !InpTradeManipulation || rangeLow <= 0) return false;
    double l1 = iLow(_Symbol,_Period,1);
    double c1 = iClose(_Symbol,_Period,1);
    double o1 = iOpen(_Symbol,_Period,1);
    // Wick below rangeLow, close back above it, bullish close
    return (l1 < rangeLow && c1 > rangeLow && c1 > o1);
}

bool IsBearManipulation()
{
    if(!isRanging || !InpTradeManipulation || rangeHigh <= 0) return false;
    double h1 = iHigh(_Symbol,_Period,1);
    double c1 = iClose(_Symbol,_Period,1);
    double o1 = iOpen(_Symbol,_Period,1);
    // Wick above rangeHigh, close back below it, bearish close
    return (h1 > rangeHigh && c1 < rangeHigh && c1 < o1);
}

//+------------------------------------------------------------------+
//| Candle pattern helpers (operate on bar[1] = last closed bar)     |
//+------------------------------------------------------------------+

// Returns true if bar[1] is a bullish engulfing (body engulfs bar[2] body)
bool IsBullEngulf()
{
    double o1 = iOpen(_Symbol,_Period,1),  c1 = iClose(_Symbol,_Period,1);
    double o2 = iOpen(_Symbol,_Period,2),  c2 = iClose(_Symbol,_Period,2);
    if(c1 <= o1) return false;             // bar[1] must be bullish
    if(c2 >= o2) return false;             // bar[2] must be bearish
    return (c1 > o2 && o1 < c2);          // body of [1] fully engulfs body of [2]
}

// Returns true if bar[1] is a bearish engulfing
bool IsBearEngulf()
{
    double o1 = iOpen(_Symbol,_Period,1),  c1 = iClose(_Symbol,_Period,1);
    double o2 = iOpen(_Symbol,_Period,2),  c2 = iClose(_Symbol,_Period,2);
    if(c1 >= o1) return false;
    if(c2 <= o2) return false;
    return (o1 > c2 && c1 < o2);
}

// Returns true if bar[1] is a doji (body ≤ DojiBodyPct% of total range)
bool IsDoji()
{
    double o = iOpen(_Symbol,_Period,1), c = iClose(_Symbol,_Period,1);
    double h = iHigh(_Symbol,_Period,1), l = iLow(_Symbol,_Period,1);
    double range = h - l;
    if(range <= 0) return false;
    return (MathAbs(c - o) / range * 100.0) <= InpDojiBodyPct;
}

// Returns true if bar[1] is a hammer (bullish rejection from bottom)
bool IsHammer()
{
    double o = iOpen(_Symbol,_Period,1), c = iClose(_Symbol,_Period,1);
    double h = iHigh(_Symbol,_Period,1), l = iLow(_Symbol,_Period,1);
    double body      = MathAbs(c - o);
    double lowerWick = MathMin(o,c) - l;
    double upperWick = h - MathMax(o,c);
    if(body <= 0) return false;
    return (lowerWick >= InpHammerWickMult * body) &&
           (upperWick <= InpHammerOppWickPct / 100.0 * body);
}

// Returns true if bar[1] is a shooting star (bearish rejection from top)
bool IsShootingStar()
{
    double o = iOpen(_Symbol,_Period,1), c = iClose(_Symbol,_Period,1);
    double h = iHigh(_Symbol,_Period,1), l = iLow(_Symbol,_Period,1);
    double body      = MathAbs(c - o);
    double upperWick = h - MathMax(o,c);
    double lowerWick = MathMin(o,c) - l;
    if(body <= 0) return false;
    return (upperWick >= InpHammerWickMult * body) &&
           (lowerWick <= InpHammerOppWickPct / 100.0 * body);
}

// Returns true if at least one bullish pattern is present on bar[1]
bool HasBullishPattern()
{
    if(!InpReqCandle) return true;
    if(InpUseEngulf && IsBullEngulf()) return true;
    if(InpUseHammer && IsHammer())     return true;
    // Doji: directionally neutral — counts only as bullish confluence (rejection of lower prices)
    // Removed from HasBearishPattern to prevent bullConf AND bearConf both being true on same bar
    if(InpUseDoji   && IsDoji())       return true;
    return false;
}

// Returns true if at least one bearish pattern is present on bar[1]
bool HasBearishPattern()
{
    if(!InpReqCandle) return true;
    if(InpUseEngulf && IsBearEngulf())   return true;
    if(InpUseHammer && IsShootingStar()) return true;
    // IsDoji intentionally excluded: doji is treated as a bullish-bias neutral pattern.
    // Including it here caused bullConf AND bearConf to both be true simultaneously,
    // which could fire opposing OB signals on the same bar in a ranging market.
    return false;
}

//+------------------------------------------------------------------+
//| Stochastic confluence                                            |
//+------------------------------------------------------------------+

// +1 = bullish stoch confirmation, -1 = bearish, 0 = no confirmation
// Logic: HTF stochastic K must be in OB/OS zone AND K must cross D on the
// last completed HTF bar (K[2] on opposite side of D[2], K[1] crossed over D[1])
int StochConfluence()
{
    if(!InpUseStoch) return 0;

    double kBuf[], dBuf[];
    ArraySetAsSeries(kBuf, true);
    ArraySetAsSeries(dBuf, true);
    if(CopyBuffer(stochHandle, 0, 0, 3, kBuf) < 3) return 0;
    if(CopyBuffer(stochHandle, 1, 0, 3, dBuf) < 3) return 0;

    double k1 = kBuf[1], k2 = kBuf[2];
    double d1 = dBuf[1], d2 = dBuf[2];

    // Bullish: K in oversold zone (0-20) AND K crossed above D
    // Cross: previous bar K was below D, current bar K is above D
    bool kInOS        = (k1 <= InpStochOS);
    bool kCrossedUpD  = (k2 < d2 && k1 > d1);
    bool bullish      = kInOS && kCrossedUpD;

    // Bearish: K in overbought zone (85-100) AND K crossed below D
    bool kInOB        = (k1 >= InpStochOB);
    bool kCrossedDnD  = (k2 > d2 && k1 < d1);
    bool bearish      = kInOB && kCrossedDnD;

    if(bullish) return  1;
    if(bearish) return -1;
    return 0;
}

//+------------------------------------------------------------------+
//| Send push notification helper                                    |
//+------------------------------------------------------------------+
void SendAlert(string msg)
{
    Print(msg);
    if(InpMetaID != "")
    {
        if(SendNotification(msg))
            Print("Push sent OK → ", InpMetaID);
        else
            Print("Push FAILED (err=", GetLastError(), ") → ", InpMetaID);
    }
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

    string biasStr;
    if(structureBias > 0)      biasStr = "BULLISH";
    else if(structureBias < 0) biasStr = "BEARISH";
    else if(isRanging)         biasStr = "RANGING";
    else                       biasStr = "UNCLEAR";

    string msg = StringFormat(
        "[%s] %s SIGNAL\n"
        "Zone: %s @ %s\n"
        "Bias: %s\n"
        "Entry: %s\n"
        "SL: %s\n"
        "TP1: %s\n"
        "TP2: %s\n"
        "TP3: %s\n"
        "TF: %s",
        sym, direction,
        zoneType, DoubleToString(zoneCenter, dg),
        biasStr,
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
            if(outSL >= outEntry) continue; // inverted SL — zone too thin or ATR too small
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
            if(outSL <= outEntry) continue; // inverted SL — zone too thin or ATR too small
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
            if(outSL >= outEntry) continue;
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
            if(outSL <= outEntry) continue;
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

            // Phase 2: trail (only once BE is set — SL must be strictly above entry)
            if(InpManualTrail && current_sl > open_p)
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

    atrZoneHandle = iATR(_Symbol, _Period, 50);
    if(atrZoneHandle == INVALID_HANDLE)
    {
        Print("SR_Zones_EA: Failed to create zone ATR handle.");
        return INIT_FAILED;
    }

    trendMAHandle = iMA(_Symbol, InpTrendTF, InpTrendMAPeriod, InpTrendMAShift,
                        InpTrendMAMethod, PRICE_CLOSE);
    if(trendMAHandle == INVALID_HANDLE)
    {
        Print("SR_Zones_EA: Failed to create trend MA handle.");
        return INIT_FAILED;
    }

    stochHandle = iStochastic(_Symbol, InpStochTF, InpStochK, InpStochD, InpStochSlowing,
                              MODE_SMA, STO_LOWHIGH);
    if(stochHandle == INVALID_HANDLE)
    {
        Print("SR_Zones_EA: Failed to create stochastic handle.");
        return INIT_FAILED;
    }

    ArrayResize(sigCenters, 50);
    ArrayResize(sigTimes,   50);
    sigCoolCount = 0;

    ArrayResize(brokenZones, 60);
    brokenCount        = 0;
    lastBreakCheckBar  = -1;

    ArrayResize(obZones, 40);
    obCount = 0;

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

    if(InpMetaID == "")
        Print("SR_Zones_EA: WARNING — InpMetaID is empty. Push notifications will be silently skipped. Set your MetaTrader device ID in the inputs.");

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
    IndicatorRelease(atrZoneHandle);
    IndicatorRelease(trendMAHandle);
    IndicatorRelease(stochHandle);
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

    // Rebuild alive zones then update swing structure bias and OBs
    RebuildAllZones();
    UpdateStructureBias();
    InvalidateOBs();

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

    int trendDir = TrendDirection(); // +1 bull, -1 bear, 0 filter off
    if(InpUseTrendFilter && trendDir != lastLogTrend)
    {
        PrintFormat("SR_Zones_EA: Trend changed → %s (HTF %s EMA%d)",
                    trendDir > 0 ? "BULL" : "BEAR",
                    EnumToString(InpTrendTF), InpTrendMAPeriod);
        lastLogTrend = trendDir;
    }

    // Evaluate candle and stochastic confluence once per bar (shared by all signal types)
    bool bullCandle  = HasBullishPattern();
    bool bearCandle  = HasBearishPattern();
    int  stochConf   = StochConfluence(); // +1 bull, -1 bear, 0 = no conf / filter off

    // When stoch enabled: require explicit +1/-1 confirmation (cross in OB/OS zone)
    bool bullConf = bullCandle && (InpUseStoch ? (stochConf == 1)  : true);
    bool bearConf = bearCandle && (InpUseStoch ? (stochConf == -1) : true);

    // Structure gate
    // +1 bullish BOS → buys only
    // -1 bearish BOS → sells only
    //  0 ranging/unclear → both allowed (zone logic decides direction)
    bool structAllowBuy  = (structureBias >= 0);
    bool structAllowSell = (structureBias <= 0);

    // Manipulation signals (override zone signals when in ranging state)
    bool bullManip = IsBullManipulation();
    bool bearManip = IsBearManipulation();

    // OB signal check (evaluated once, used in dispatch below)
    // Use separate output variables so bear OB cannot overwrite bull OB data
    double obBuyEntry = 0, obBuySL = 0, obBuyCenter = 0; string obBuyType = "";
    double obSelEntry = 0, obSelSL = 0, obSelCenter = 0; string obSelType = "";
    bool   hasBullOB = structAllowBuy  && CheckOBBuySignal (atr, obBuyEntry, obBuySL, obBuyCenter, obBuyType);
    bool   hasBearOB = structAllowSell && CheckOBSellSignal(atr, obSelEntry, obSelSL, obSelCenter, obSelType);

    double entry = 0, sl = 0, zoneCenter = 0;
    double tp1 = 0, tp2 = 0, tp3 = 0;
    string zoneType = "";

    int barIdx2 = (int)SeriesInfoInteger(_Symbol, _Period, SERIES_BARS_COUNT) - 1;

    // Signal dispatch priority (highest quality first):
    //   1. OB (CHoCH/BOS) — single-candle precision, tightest SL
    //   2. Retest         — flipped zone, strong structural confluence
    //   3. Raw bounce     — live zone touch (only when InpRetestOnly=false)
    //   4. Sweep          — ranging manipulation / stop hunt reversal

    // --- 1a. BUY Order Block ---
    if(hasBullOB && bullConf)
    {
        double tp1ob = 0, tp2ob = 0, tp3ob = 0;
        FindTpTargets(obBuyEntry, 1, tp1ob, tp2ob, tp3ob);
        RecordCooldown(obBuyCenter);
        Print("SR_Zones_EA: BUY OB | Type=", obBuyType, " Center=", obBuyCenter,
              " Entry=", obBuyEntry, " SL=", obBuySL);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("BUY OB", obBuyEntry, obBuySL, tp1ob, tp2ob, tp3ob, obBuyType, obBuyCenter);
        else if(IsStopLevelValid(_Symbol, obBuySL, ORDER_TYPE_BUY))
        {
            if(!pyramid.OpenInitial(POSITION_TYPE_BUY, obBuyEntry, obBuySL, InpLotInitial))
                Print("SR_Zones_EA: BUY OB OpenInitial failed.");
            else
                SendTradeAlert("BUY OB", obBuyEntry, obBuySL, tp1ob, tp2ob, tp3ob, InpLotInitial);
        }
        return;
    }

    // --- 1b. SELL Order Block ---
    if(hasBearOB && bearConf)
    {
        double tp1ob = 0, tp2ob = 0, tp3ob = 0;
        FindTpTargets(obSelEntry, -1, tp1ob, tp2ob, tp3ob);
        RecordCooldown(obSelCenter);
        Print("SR_Zones_EA: SELL OB | Type=", obSelType, " Center=", obSelCenter,
              " Entry=", obSelEntry, " SL=", obSelSL);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("SELL OB", obSelEntry, obSelSL, tp1ob, tp2ob, tp3ob, obSelType, obSelCenter);
        else if(IsStopLevelValid(_Symbol, obSelSL, ORDER_TYPE_SELL))
        {
            if(!pyramid.OpenInitial(POSITION_TYPE_SELL, obSelEntry, obSelSL, InpLotInitial))
                Print("SR_Zones_EA: SELL OB OpenInitial failed.");
            else
                SendTradeAlert("SELL OB", obSelEntry, obSelSL, tp1ob, tp2ob, tp3ob, InpLotInitial);
        }
        return;
    }

    // --- 2a. BUY retest (broken resistance → flipped support) ---
    if((trendDir >= 0) && structAllowBuy && bullConf &&
       CheckRetestBuy(atr, entry, sl, zoneCenter, zoneType, barIdx2))
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

    // --- 2b. SELL retest (broken support → flipped resistance) ---
    if((trendDir <= 0) && structAllowSell && bearConf &&
       CheckRetestSell(atr, entry, sl, zoneCenter, zoneType, barIdx2))
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
        return;
    }

    // --- 3a. BUY raw bounce (live support touch) ---
    if(!InpRetestOnly && (trendDir >= 0) && structAllowBuy && bullConf &&
       CheckBuySignal(atr, entry, sl, zoneCenter, zoneType))
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

    // --- 3b. SELL raw bounce (live resistance touch) ---
    if(!InpRetestOnly && (trendDir <= 0) && structAllowSell && bearConf &&
       CheckSellSignal(atr, entry, sl, zoneCenter, zoneType))
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

    // --- Manipulation signals (ranging market only) ---
    // Bullish sweep: wick below rangeLow, close back inside → accumulation → BUY
    if(bullManip && bullConf && CooldownOk(rangeLow, atr))
    {
        double atrV = atr;
        entry       = iClose(_Symbol, _Period, 1);
        sl          = NormalizeDouble(rangeLow - atrV * InpRetestSlBuffer, _Digits);
        FindTpTargets(entry, 1, tp1, tp2, tp3);
        zoneCenter  = rangeLow;
        zoneType    = "Range Low Sweep";
        RecordCooldown(zoneCenter);
        Print("SR_Zones_EA: BULL MANIPULATION | RangeLow=", rangeLow,
              " Entry=", entry, " SL=", sl);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("BUY SWEEP", entry, sl, tp1, tp2, tp3, zoneType, zoneCenter);
        else if(IsStopLevelValid(_Symbol, sl, ORDER_TYPE_BUY))
        {
            if(!pyramid.OpenInitial(POSITION_TYPE_BUY, entry, sl, InpLotInitial))
                Print("SR_Zones_EA: BUY SWEEP OpenInitial returned false.");
            else
                SendTradeAlert("BUY SWEEP", entry, sl, tp1, tp2, tp3, InpLotInitial);
        }
        return;
    }

    // Bearish sweep: wick above rangeHigh, close back inside → distribution → SELL
    if(bearManip && bearConf && CooldownOk(rangeHigh, atr))
    {
        double atrV = atr;
        entry       = iClose(_Symbol, _Period, 1);
        sl          = NormalizeDouble(rangeHigh + atrV * InpRetestSlBuffer, _Digits);
        FindTpTargets(entry, -1, tp1, tp2, tp3);
        zoneCenter  = rangeHigh;
        zoneType    = "Range High Sweep";
        RecordCooldown(zoneCenter);
        Print("SR_Zones_EA: BEAR MANIPULATION | RangeHigh=", rangeHigh,
              " Entry=", entry, " SL=", sl);

        if(InpMode == SIGNAL_MODE)
            SendSignalAlert("SELL SWEEP", entry, sl, tp1, tp2, tp3, zoneType, zoneCenter);
        else if(IsStopLevelValid(_Symbol, sl, ORDER_TYPE_SELL))
        {
            if(!pyramid.OpenInitial(POSITION_TYPE_SELL, entry, sl, InpLotInitial))
                Print("SR_Zones_EA: SELL SWEEP OpenInitial returned false.");
            else
                SendTradeAlert("SELL SWEEP", entry, sl, tp1, tp2, tp3, InpLotInitial);
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
