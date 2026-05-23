//+------------------------------------------------------------------+
//|                   StochFib_MTF_Alert.mq5                         |
//|  Dual-TF Stochastic + Dynamic Fib Zone Gate                      |
//|  v2.0  – TF2 sets direction (OB/OS), TF1 triggers (any zone)    |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   TF2 (slow): K/D cross from OB → SELL direction                |
//|               K/D cross from OS → BUY  direction                |
//|               Mid-zone TF2 crosses are ignored                   |
//|   TF1 (fast): K/D cross in any zone (OB / OS / mid 30-70)      |
//|               Fires if TF1 direction == TF2 direction            |
//|               + price in fib zone or SBR/RBS level              |
//|                                                                  |
//|  SBR tag: price near old swing low after break (was support)     |
//|  RBS tag: price near old swing high after break (was resistance) |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "2.00"
#property description "Dual-TF Stoch: TF2 direction + TF1 trigger + Fib/SBR gate"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  CONSTANTS
//════════════════════════════════════════════════════════════════════
#define SIG_NONE  0
#define SIG_BUY   1
#define SIG_SELL  2

const double FIB_RATIO[7] = {0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0};
const string FIB_LABEL[7] = {"0", "0.236", "0.382", "0.5", "0.618", "0.786", "1"};

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1 = PERIOD_M6;   // TF1 – trigger (faster)
input ENUM_TIMEFRAMES InpTF2 = PERIOD_H1;   // TF2 – direction (slower)

input group "══════ Stochastic – TF1 (trigger) ══════"
input int    InpStoch_K    = 26;
input int    InpStoch_D    = 7;
input int    InpStoch_Slow = 11;

input group "══════ Stochastic – TF2 (direction) ══════"
input int    InpStoch_K2    = 14;
input int    InpStoch_D2    = 3;
input int    InpStoch_Slow2 = 9;

input group "══════ OB / OS Levels ══════"
input double InpOB_Level   = 80.0;
input double InpOS_Level   = 20.0;
input int    InpOSLookback = 20;   // bars to scan for OB/OS touch on both TFs

input group "══════ Cross Zone Filter (both TFs) ══════"
input double InpSellMinK = 70.0;  // SELL cross valid only if K >= this (OB or near-OB pullback)
input double InpBuyMaxK  = 40.0;  // BUY  cross valid only if K <= this (OS or near-OS bounce)

input group "══════ Signal Cooldown ══════"
input int    InpSignalCooldownMin = 60;

input group "══════ Fib Zone Filter ══════"
input ENUM_TIMEFRAMES InpFibTF         = PERIOD_M30;
input int             InpFibLookback   = 100;
input bool            InpFibZoneEnable  = true;   // Enable fib zone gate for entries
input double          InpFibBuyZoneMax  = 0.382;
input double          InpFibSellZoneMin = 0.618;
input double          InpSBR_Tol       = 0.05;

input group "══════ SBR / RBS Rejection ══════"
input double InpSBR_DeepExt       = 0.10;
input double InpRBS_DeepExt       = 0.10;
input int    InpRejectionLookback = 5;

input group "══════ TP / SL Targets ══════"
input int    InpSLLookback  = 20;
input int    InpSLFallback  = 500;
input double InpTP1_RR      = 1.0;
input double InpTP2_RR      = 2.0;
input double InpTP3_RR      = 3.0;

input group "══════ Notification Settings ══════"
input bool InpEnablePush  = true;
input bool InpEnablePopup = false;
input bool InpEnablePrint = true;

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;

// TF bar guards
datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

// TF2 direction – set by OB/OS crosses only; persists until opposite OB/OS cross
int g_tf2_dir = SIG_NONE;

// Cooldown
int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;
datetime g_fired_bar        = 0;   // last TF1 bar that fired a signal

// Fib anchor
double   g_fibSwingHigh = 0.0, g_fibSwingLow  = 0.0;
double   g_oldSwingHigh = 0.0, g_oldSwingLow  = 0.0;
bool     g_hasOldHigh   = false, g_hasOldLow  = false;
int      g_trendBias    = 0;   // +1=uptrend, -1=downtrend
datetime g_fibBar       = 0;

// Live K – silent tracking
double g_liveK_1 = 0.0, g_liveK_2 = 0.0;

//+------------------------------------------------------------------+
//  OnInit
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1 = g_lastBar_2 = 0;
   g_tf2_dir   = SIG_NONE;
   g_lastCooldownSig  = SIG_NONE;
   g_lastCooldownTime = 0;
   g_fired_bar        = 0;
   g_fibSwingHigh = g_fibSwingLow = 0.0;
   g_oldSwingHigh = g_oldSwingLow = 0.0;
   g_hasOldHigh   = g_hasOldLow  = false;
   g_trendBias    = 0;
   g_fibBar       = 0;
   g_liveK_1      = g_liveK_2    = 0.0;

   LoadFibState();

   g_h_stoch_1 = iStochastic(_Symbol, InpTF1,
                              InpStoch_K, InpStoch_D, InpStoch_Slow,
                              MODE_SMA, STO_LOWHIGH);
   if(g_h_stoch_1 == INVALID_HANDLE)
   { Alert("StochFib: Failed Stoch TF1 handle"); return INIT_FAILED; }

   g_h_stoch_2 = iStochastic(_Symbol, InpTF2,
                              InpStoch_K2, InpStoch_D2, InpStoch_Slow2,
                              MODE_SMA, STO_LOWHIGH);
   if(g_h_stoch_2 == INVALID_HANDLE)
   { Alert("StochFib: Failed Stoch TF2 handle"); return INIT_FAILED; }

   EventSetTimer(2);

   Print("StochFib v2.0 loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1), " Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | TF2:", TFName(InpTF2), " Stoch(", InpStoch_K2, ",", InpStoch_D2, ",", InpStoch_Slow2, ")",
         " | FibTF:", TFName(InpFibTF), " Lookback:", InpFibLookback,
         " BuyZone:0→", InpFibBuyZoneMax, " SellZone:", InpFibSellZoneMin, "→1");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//  OnDeinit
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_h_stoch_1 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_1);
   if(g_h_stoch_2 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_2);
}

//+------------------------------------------------------------------+
//  OnTimer / OnCalculate
//+------------------------------------------------------------------+
void OnTimer() { CheckAllTimeframes(); }

int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   CheckAllTimeframes();
   return rates_total;
}

//+------------------------------------------------------------------+
//  UpdateLiveK – current forming-bar K on both TFs
//+------------------------------------------------------------------+
void UpdateLiveK()
{
   double k[1];
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE, 0, 1, k) == 1) g_liveK_1 = k[0];
   if(CopyBuffer(g_h_stoch_2, MAIN_LINE, 0, 1, k) == 1) g_liveK_2 = k[0];
}

//+------------------------------------------------------------------+
//  SilentWatch – journal snapshot every TF1/TF2 bar change
//+------------------------------------------------------------------+
void SilentWatch()
{
   if(!InpEnablePrint)          return;
   if(g_tf2_dir == SIG_NONE)   return;  // no direction established yet – nothing to watch

   double range  = g_fibSwingHigh - g_fibSwingLow;
   double price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double fibPos = (range > 0) ? (price - g_fibSwingLow) / range : -1.0;

   string zone  = (fibPos >= 0.0 && fibPos <= InpFibBuyZoneMax)   ? "BUY ZONE"  :
                  (fibPos >= InpFibSellZoneMin && fibPos <= 1.0)   ? "SELL ZONE" : "DEAD ZONE";
   string tf2st = (g_tf2_dir == SIG_BUY ? "BUY" : g_tf2_dir == SIG_SELL ? "SELL" : "none");

   Print("[WATCH] ",
         TFName(InpTF1), " K=", DoubleToString(g_liveK_1, 1),
         " | ", TFName(InpTF2), " K=", DoubleToString(g_liveK_2, 1), " dir=", tf2st,
         " | fib=", FibPosLabel(fibPos), " (", zone, ")");
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes – main dispatch
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   UpdateFibSwing();
   UpdateLiveK();
   UpdateTF2Direction();
   CheckTF1Signal();
}

//════════════════════════════════════════════════════════════════════
//  HELPER FUNCTIONS
//════════════════════════════════════════════════════════════════════

string TFName(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

string SignalTypeName(int sig) { return sig == SIG_BUY ? "BUY" : "SELL"; }
bool IsBullish(int s) { return s == SIG_BUY;  }
bool IsBearish(int s) { return s == SIG_SELL; }

//+------------------------------------------------------------------+
//  GlobalVariable key builder
//+------------------------------------------------------------------+
string GVName(string suffix)
{
   return "SF_" + _Symbol + "_" + TFName(InpFibTF) + "_" + suffix;
}

//+------------------------------------------------------------------+
//  SaveFibState – persist fib anchors + TF2 direction to GlobalVariables
//+------------------------------------------------------------------+
void SaveFibState()
{
   GlobalVariableSet(GVName("SH"),  g_fibSwingHigh);
   GlobalVariableSet(GVName("SL"),  g_fibSwingLow);
   GlobalVariableSet(GVName("OSH"), g_oldSwingHigh);
   GlobalVariableSet(GVName("OSL"), g_oldSwingLow);
   GlobalVariableSet(GVName("HOH"), g_hasOldHigh ? 1.0 : 0.0);
   GlobalVariableSet(GVName("HOL"), g_hasOldLow  ? 1.0 : 0.0);
   GlobalVariableSet(GVName("TRB"), (double)g_trendBias);
   GlobalVariableSet(GVName("TD2"), (double)g_tf2_dir);
}

//+------------------------------------------------------------------+
//  LoadFibState – restore state from GlobalVariables on restart
//+------------------------------------------------------------------+
bool LoadFibState()
{
   double sh = 0, sl = 0;
   if(!GlobalVariableGet(GVName("SH"), sh)) return false;
   if(!GlobalVariableGet(GVName("SL"), sl)) return false;
   if(sh <= 0 || sl <= 0 || sh <= sl)       return false;

   g_fibSwingHigh = sh;
   g_fibSwingLow  = sl;

   double osh = 0, osl = 0, hoh = 0, hol = 0, trb = 0, td2 = 0;
   GlobalVariableGet(GVName("OSH"), osh); g_oldSwingHigh = osh;
   GlobalVariableGet(GVName("OSL"), osl); g_oldSwingLow  = osl;
   GlobalVariableGet(GVName("HOH"), hoh); g_hasOldHigh   = (hoh > 0.5);
   GlobalVariableGet(GVName("HOL"), hol); g_hasOldLow    = (hol > 0.5);
   GlobalVariableGet(GVName("TRB"), trb); g_trendBias    = (int)MathRound(trb);
   GlobalVariableGet(GVName("TD2"), td2); g_tf2_dir      = (int)MathRound(td2);

   Print("[FIB] Restored: High=", DoubleToString(g_fibSwingHigh, _Digits),
         "  Low=",  DoubleToString(g_fibSwingLow,  _Digits),
         "  SBR:", (g_hasOldLow  ? DoubleToString(g_oldSwingLow,  _Digits) : "none"),
         "  RBS:", (g_hasOldHigh ? DoubleToString(g_oldSwingHigh, _Digits) : "none"),
         "  TrendBias:", (g_trendBias == 1 ? "UP" : g_trendBias == -1 ? "DOWN" : "none"),
         "  TF2dir:", (g_tf2_dir == SIG_BUY ? "BUY" : g_tf2_dir == SIG_SELL ? "SELL" : "none"));
   return true;
}

//+------------------------------------------------------------------+
//  FibPosLabel – nearest standard fib label for a 0.0→1.0 ratio
//+------------------------------------------------------------------+
string FibPosLabel(double pos)
{
   int    best = 0;
   double minD = MathAbs(pos - FIB_RATIO[0]);
   for(int i = 1; i < 7; i++)
   {
      double d = MathAbs(pos - FIB_RATIO[i]);
      if(d < minD) { minD = d; best = i; }
   }
   return FIB_LABEL[best];
}

//+------------------------------------------------------------------+
//  UpdateFibSwing – recalculate fib anchors on each FibTF bar close
//+------------------------------------------------------------------+
void UpdateFibSwing()
{
   datetime barTimes[2];
   if(CopyTime(_Symbol, InpFibTF, 0, 2, barTimes) < 2) return;
   if(barTimes[1] == g_fibBar) return;
   g_fibBar = barTimes[1];

   if(g_fibSwingHigh == 0.0 && g_fibSwingLow == 0.0)
   {
      int hiIdx = iHighest(_Symbol, InpFibTF, MODE_HIGH, InpFibLookback, 1);
      int loIdx = iLowest (_Symbol, InpFibTF, MODE_LOW,  InpFibLookback, 1);
      if(hiIdx < 0 || loIdx < 0) return;
      g_fibSwingHigh = iHigh(_Symbol, InpFibTF, hiIdx);
      g_fibSwingLow  = iLow (_Symbol, InpFibTF, loIdx);
      Print("[FIB] Initialised from lookback: High=", DoubleToString(g_fibSwingHigh, _Digits),
            "  Low=", DoubleToString(g_fibSwingLow, _Digits));
      SaveFibState();
      return;
   }

   double cls[1];
   if(CopyClose(_Symbol, InpFibTF, 1, 1, cls) < 1) return;
   double close = cls[0];

   // Swing LOW broken → old low becomes SBR; rescan both anchors
   if(close < g_fibSwingLow)
   {
      g_oldSwingLow = g_fibSwingLow;
      g_hasOldLow   = true;
      g_trendBias   = -1;
      int loIdx = iLowest (_Symbol, InpFibTF, MODE_LOW,  InpFibLookback, 1);
      int hiIdx = iHighest(_Symbol, InpFibTF, MODE_HIGH, InpFibLookback, 1);
      if(loIdx >= 0) g_fibSwingLow  = iLow (_Symbol, InpFibTF, loIdx);
      if(hiIdx >= 0) g_fibSwingHigh = iHigh(_Symbol, InpFibTF, hiIdx);
      Print("[FIB] Swing LOW broken → range=[", DoubleToString(g_fibSwingLow, _Digits),
            ",", DoubleToString(g_fibSwingHigh, _Digits), "]",
            "  SBR level=", DoubleToString(g_oldSwingLow, _Digits));
      SaveFibState();
   }
   // Swing HIGH broken → old high becomes RBS; rescan both anchors
   else if(close > g_fibSwingHigh)
   {
      g_oldSwingHigh = g_fibSwingHigh;
      g_hasOldHigh   = true;
      g_trendBias    = +1;
      int hiIdx = iHighest(_Symbol, InpFibTF, MODE_HIGH, InpFibLookback, 1);
      int loIdx = iLowest (_Symbol, InpFibTF, MODE_LOW,  InpFibLookback, 1);
      if(hiIdx >= 0) g_fibSwingHigh = iHigh(_Symbol, InpFibTF, hiIdx);
      if(loIdx >= 0) g_fibSwingLow  = iLow (_Symbol, InpFibTF, loIdx);
      Print("[FIB] Swing HIGH broken → range=[", DoubleToString(g_fibSwingLow, _Digits),
            ",", DoubleToString(g_fibSwingHigh, _Digits), "]",
            "  RBS level=", DoubleToString(g_oldSwingHigh, _Digits));
      SaveFibState();
   }
}

//+------------------------------------------------------------------+
//  CheckFibZone – normal fib zone gate
//  BUY:  fibPos in [0, InpFibBuyZoneMax]
//  SELL: fibPos in [InpFibSellZoneMin, 1]
//+------------------------------------------------------------------+
bool CheckFibZone(int sigType, double &fibPos, string &fibTag)
{
   fibPos = -1.0;
   fibTag = "";

   double range = g_fibSwingHigh - g_fibSwingLow;
   if(range <= 0.0) return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   fibPos = (price - g_fibSwingLow) / range;

   // No trend filter: TF2 OB/OS gate already validates structural context.
   // Blocking here would suppress valid OB/OS-confirmed signals during trending markets.

   if(IsBullish(sigType))
      return (fibPos >= 0.0 && fibPos <= InpFibBuyZoneMax);
   else
      return (fibPos >= InpFibSellZoneMin && fibPos <= 1.0);
}

//+------------------------------------------------------------------+
//  CheckSBRRBS – direction-enforced role-flip zone check
//  SBR: SELL only – price testing old swing low (broken support → resistance)
//  RBS: BUY  only – price testing old swing high (broken resistance → support)
//+------------------------------------------------------------------+
bool CheckSBRRBS(int stochState, double &fibPos, string &roleTag, double &levelPrice)
{
   fibPos = -1.0; roleTag = ""; levelPrice = 0.0;

   double range = g_fibSwingHigh - g_fibSwingLow;
   if(range <= 0.0) return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(IsBearish(stochState) && g_hasOldLow)
   {
      double zoneLo = g_oldSwingLow - InpSBR_Tol     * range;
      double zoneHi = g_oldSwingLow + InpSBR_DeepExt * range;
      if(price >= zoneLo && price <= zoneHi)
      {
         fibPos     = (price - g_fibSwingLow) / range;
         roleTag    = "SBR";
         levelPrice = g_oldSwingLow;
         Print("[SBR] price=", DoubleToString(price, _Digits),
               " zone=[", DoubleToString(zoneLo, _Digits), ",", DoubleToString(zoneHi, _Digits), "]",
               " fibPos=", DoubleToString(fibPos, 3));
         return true;
      }
   }

   if(IsBullish(stochState) && g_hasOldHigh)
   {
      double zoneLo = g_oldSwingHigh - InpRBS_DeepExt * range;
      double zoneHi = g_oldSwingHigh + InpSBR_Tol     * range;
      if(price >= zoneLo && price <= zoneHi)
      {
         fibPos     = (price - g_fibSwingLow) / range;
         roleTag    = "RBS";
         levelPrice = g_oldSwingHigh;
         Print("[RBS] price=", DoubleToString(price, _Digits),
               " zone=[", DoubleToString(zoneLo, _Digits), ",", DoubleToString(zoneHi, _Digits), "]",
               " fibPos=", DoubleToString(fibPos, 3));
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//  HasRejectionCandle – scan TF1 bars for rejection pattern at level
//+------------------------------------------------------------------+
bool HasRejectionCandle(bool bearish, double levelPrice, ENUM_TIMEFRAMES tf, int lookback)
{
   double opens[], highs[], lows[], closes[];
   if(CopyOpen (_Symbol, tf, 1, lookback, opens)  < lookback) return false;
   if(CopyHigh (_Symbol, tf, 1, lookback, highs)  < lookback) return false;
   if(CopyLow  (_Symbol, tf, 1, lookback, lows)   < lookback) return false;
   if(CopyClose(_Symbol, tf, 1, lookback, closes) < lookback) return false;

   double range    = g_fibSwingHigh - g_fibSwingLow;
   double priceTol = InpSBR_Tol * range;

   for(int i = 0; i < lookback; i++)
   {
      double o = opens[i], h = highs[i], l = lows[i], c = closes[i];
      double cRange = h - l;
      if(cRange <= 0.0) continue;
      double body = MathAbs(c - o);

      if(bearish)
      {
         if(h < levelPrice - priceTol)                 continue;
         if(l > levelPrice + priceTol * 2)             continue;
         if(MathMin(o, c) > levelPrice + priceTol * 2) continue;

         double upperWick  = h - MathMax(o, c);
         bool shootingStar = (body > 0) && (upperWick >= 2.0 * body) && (c < (h + l) * 0.5);
         bool doji         = (body <= 0.10 * cRange);
         bool outsideBar   = false, engulfing = false;
         if(i + 1 < lookback)
         {
            double ph = highs[i+1], pl = lows[i+1], pO = opens[i+1], pC = closes[i+1];
            outsideBar = (h > ph) && (l < pl) && (c < o);
            engulfing  = (c < o) && (o >= MathMax(pO, pC)) && (c <= MathMin(pO, pC));
         }
         if(shootingStar || doji || outsideBar || engulfing)
         {
            string pt = shootingStar ? "ShootingStar" : doji ? "Doji" : outsideBar ? "OutsideBar" : "BearEngulf";
            Print("[REJECT-SBR] ", pt, " H=", DoubleToString(h, _Digits),
                  " level=", DoubleToString(levelPrice, _Digits), " bar=", i+1, " ago");
            return true;
         }
      }
      else
      {
         if(l > levelPrice + priceTol)                 continue;
         if(h < levelPrice - priceTol * 2)             continue;
         if(MathMax(o, c) < levelPrice - priceTol * 2) continue;

         double lowerWick = MathMin(o, c) - l;
         bool hammer      = (body > 0) && (lowerWick >= 2.0 * body) && (c > (h + l) * 0.5);
         bool doji        = (body <= 0.10 * cRange);
         bool outsideBar  = false, engulfing = false;
         if(i + 1 < lookback)
         {
            double ph = highs[i+1], pl = lows[i+1], pO = opens[i+1], pC = closes[i+1];
            outsideBar = (h > ph) && (l < pl) && (c > o);
            engulfing  = (c > o) && (o <= MathMin(pO, pC)) && (c >= MathMax(pO, pC));
         }
         if(hammer || doji || outsideBar || engulfing)
         {
            string pt = hammer ? "Hammer" : doji ? "Doji" : outsideBar ? "OutsideBar" : "BullEngulf";
            Print("[REJECT-RBS] ", pt, " L=", DoubleToString(l, _Digits),
                  " level=", DoubleToString(levelPrice, _Digits), " bar=", i+1, " ago");
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//  PassesCooldown
//+------------------------------------------------------------------+
bool PassesCooldown(int sigType, datetime t)
{
   if(InpSignalCooldownMin <= 0)    return true;
   if(g_lastCooldownSig != sigType) return true;
   return (t - g_lastCooldownTime) >= (datetime)(InpSignalCooldownMin * 60);
}

//+------------------------------------------------------------------+
//  CalcTPSL – swing SL + R:R TP targets
//+------------------------------------------------------------------+
void CalcTPSL(int sigType, double entry,
              double &sl, double &tp1, double &tp2, double &tp3)
{
   double arr[];
   ArrayResize(arr, InpSLLookback);
   double risk;

   if(IsBullish(sigType))
   {
      sl   = (CopyLow(_Symbol, InpTF1, 1, InpSLLookback, arr) == InpSLLookback)
             ? arr[ArrayMinimum(arr)]
             : entry - InpSLFallback * _Point;
      risk = entry - sl;
      if(risk <= 0)
      {
         Print("[SL WARN] BUY SL at or above entry – using fallback ", InpSLFallback, " pts");
         risk = InpSLFallback * _Point;
      }
      tp1 = entry + risk * InpTP1_RR;
      tp2 = entry + risk * InpTP2_RR;
      tp3 = entry + risk * InpTP3_RR;
   }
   else
   {
      sl   = (CopyHigh(_Symbol, InpTF1, 1, InpSLLookback, arr) == InpSLLookback)
             ? arr[ArrayMaximum(arr)]
             : entry + InpSLFallback * _Point;
      risk = sl - entry;
      if(risk <= 0)
      {
         Print("[SL WARN] SELL SL at or below entry – using fallback ", InpSLFallback, " pts");
         risk = InpSLFallback * _Point;
      }
      tp1 = entry - risk * InpTP1_RR;
      tp2 = entry - risk * InpTP2_RR;
      tp3 = entry - risk * InpTP3_RR;
   }
}

//+------------------------------------------------------------------+
//  FireSignal – single alert with SL/TP
//  🟢 BUY (SBR) XAUUSD.p @ FIB 0.236 [M4:OS H1:BUY]  SL:...  TP1:...
//+------------------------------------------------------------------+
void FireSignal(int sigType, double fibPos, string fibTag)
{
   double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp1, tp2, tp3;
   CalcTPSL(sigType, entry, sl, tp1, tp2, tp3);

   string emoji  = IsBullish(sigType) ? "🟢" : "🔴";
   string tag    = fibTag == "" ? "" : " (" + fibTag + ")";

   string msg = emoji + " " + SignalTypeName(sigType) + tag
              + " " + _Symbol
              + "  SL:"  + DoubleToString(sl,  _Digits)
              + "  TP1:" + DoubleToString(tp1, _Digits)
              + "  TP2:" + DoubleToString(tp2, _Digits)
              + "  TP3:" + DoubleToString(tp3, _Digits);

   if(InpEnablePush && !SendNotification(msg)) Print("Push failed.");
   if(InpEnablePopup) Alert(msg);
   if(InpEnablePrint) Print(msg);
}

//+------------------------------------------------------------------+
//  UpdateTF2Direction – OB/OS crosses on TF2 set the market direction.
//  Mid-zone TF2 crosses are ignored – they don't change direction.
//+------------------------------------------------------------------+
void UpdateTF2Direction()
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, InpTF2, 0, 3, barTimes) < 3) return;
   if(barTimes[1] == g_lastBar_2) return;
   g_lastBar_2 = barTimes[1];

   int    kCopy = InpOSLookback + 2;
   double k_buf[];
   double d_buf[3];
   ArrayResize(k_buf, kCopy);
   if(CopyBuffer(g_h_stoch_2, MAIN_LINE,   0, kCopy, k_buf) < kCopy) return;
   if(CopyBuffer(g_h_stoch_2, SIGNAL_LINE, 0, 3,     d_buf) < 3)     return;

   double k1 = k_buf[1], d1 = d_buf[1];
   double k2 = k_buf[2], d2 = d_buf[2];

   bool crossUp   = (k2 <= d2) && (k1 > d1);
   bool crossDown = (k2 >= d2) && (k1 < d1);
   if(!crossUp && !crossDown) return;

   // Same zone filter as TF1: K value at cross must be in OB/OS or valid near-zone
   if(crossDown && k1 >= InpSellMinK)
   {
      string zone = (k1 >= InpOB_Level) ? "OB" : "nearOB";
      g_tf2_dir = SIG_SELL;
      Print("[TF2 DIR] → SELL from ", zone, "  K=", DoubleToString(k1, 2));
      SaveFibState();
      SilentWatch();
   }
   else if(crossUp && k1 <= InpBuyMaxK)
   {
      string zone = (k1 <= InpOS_Level) ? "OS" : "nearOS";
      g_tf2_dir = SIG_BUY;
      Print("[TF2 DIR] → BUY from ", zone, "  K=", DoubleToString(k1, 2));
      SaveFibState();
      SilentWatch();
   }
   else
   {
      Print("[TF2 NOISE] cross ignored K=", DoubleToString(k1, 2),
            " (dir stays ", (g_tf2_dir == SIG_BUY ? "BUY" : g_tf2_dir == SIG_SELL ? "SELL" : "none"), ")");
   }
}

//+------------------------------------------------------------------+
//  CheckTF1Signal – TF1 bar cross; fires when aligned with TF2 direction
//  Any zone cross (OB / OS / mid 30-70) is valid if TF2 agrees.
//  Signal message labels TF1 zone so user can gauge signal quality.
//+------------------------------------------------------------------+
void CheckTF1Signal()
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, InpTF1, 0, 3, barTimes) < 3) return;
   if(barTimes[1] == g_lastBar_1) return;
   g_lastBar_1 = barTimes[1];

   // Always emit WATCH on TF1 bar change
   SilentWatch();

   if(g_tf2_dir == SIG_NONE) return;  // no TF2 direction established yet

   int    kCopy = InpOSLookback + 2;
   double k_buf[];
   double d_buf[3];
   ArrayResize(k_buf, kCopy);
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE,   0, kCopy, k_buf) < kCopy) return;
   if(CopyBuffer(g_h_stoch_1, SIGNAL_LINE, 0, 3,     d_buf) < 3)     return;

   double k1 = k_buf[1], d1 = d_buf[1];
   double k2 = k_buf[2], d2 = d_buf[2];

   bool crossUp   = (k2 <= d2) && (k1 > d1);
   bool crossDown = (k2 >= d2) && (k1 < d1);
   if(!crossUp && !crossDown) return;

   int tf1sig = crossUp ? SIG_BUY : SIG_SELL;

   // TF1 zone filter: block crosses in the 40-70 noise band
   // SELL valid: K >= InpTF1SellMinK (e.g. 70 – near-OB or OB)
   // BUY  valid: K <= InpTF1BuyMaxK  (e.g. 40 – near-OS or OS)
   if(tf1sig == SIG_SELL && k1 < InpSellMinK)
   {
      Print("[TF1 NOISE] SELL cross K=", DoubleToString(k1, 1),
            " < ", InpSellMinK, " – ignored");
      return;
   }
   if(tf1sig == SIG_BUY && k1 > InpBuyMaxK)
   {
      Print("[TF1 NOISE] BUY cross K=", DoubleToString(k1, 1),
            " > ", InpBuyMaxK, " – ignored");
      return;
   }

   // Zone label for signal quality context in message
   string tf1Zone;
   if(crossUp)
      tf1Zone = (k1 <= InpOS_Level) ? "OS" : "nearOS";   // BUY: OS or 20-40 near-OS
   else
      tf1Zone = (k1 >= InpOB_Level) ? "OB" : "nearOB";   // SELL: OB or 70-80 near-OB

   Print("[TF1] ", SignalTypeName(tf1sig), " cross ", tf1Zone,
         "  K=", DoubleToString(k1, 2),
         "  TF2 dir=", (g_tf2_dir == SIG_BUY ? "BUY" : "SELL"));

   // Must align with TF2 direction
   if(tf1sig != g_tf2_dir)
   {
      Print("[WAIT] TF1=", SignalTypeName(tf1sig),
            " TF2=", SignalTypeName(g_tf2_dir), " – mismatch");
      return;
   }

   // Same-bar guard (shouldn't happen but safety check)
   if(barTimes[1] == g_fired_bar) return;

   // Fib zone gate
   double fibPos = -1.0; string fibTag = "";
   bool   zonePassed = false;

   if(InpFibZoneEnable && CheckFibZone(tf1sig, fibPos, fibTag))
   {
      zonePassed = true;
   }
   else
   {
      double levelPrice;
      if(CheckSBRRBS(tf1sig, fibPos, fibTag, levelPrice))
      {
         if(HasRejectionCandle(IsBearish(tf1sig), levelPrice, InpTF1, InpRejectionLookback))
            zonePassed = true;
         else
            Print("[SBR/RBS BLOCK] No rejection candle at ",
                  DoubleToString(levelPrice, _Digits), " for ", fibTag);
      }
   }

   if(!zonePassed)
   {
      // Compute live fib pos for the block log
      double range = g_fibSwingHigh - g_fibSwingLow;
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lp    = (range > 0) ? (price - g_fibSwingLow) / range : -1.0;
      Print("[FIB BLOCK] ", SignalTypeName(tf1sig),
            " blocked  fib=", DoubleToString(lp, 3),
            " K=", DoubleToString(k1, 1));
      return;
   }

   // Cooldown check
   if(!PassesCooldown(tf1sig, barTimes[1]))
   {
      Print("[COOLDOWN] ", SignalTypeName(tf1sig), " blocked – within ", InpSignalCooldownMin, "min");
      return;
   }

   // Fire
   FireSignal(tf1sig, fibPos, fibTag);

   g_fired_bar        = barTimes[1];
   g_lastCooldownSig  = tf1sig;
   g_lastCooldownTime = barTimes[1];
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
