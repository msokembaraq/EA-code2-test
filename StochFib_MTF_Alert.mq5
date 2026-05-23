//+------------------------------------------------------------------+
//|                   StochFib_MTF_Alert.mq5                         |
//|  Dual-TF Stochastic + Fib Zone / SBR-RBS Gate                   |
//|  v2.1                                                            |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   TF2 (slow): K/D cross in OB/OS or near-zone sets direction    |
//|               Mid-zone (40-70) TF2 crosses are ignored           |
//|   TF1 (fast): K/D cross valid if K>=InpSellMinK / K<=InpBuyMaxK |
//|               Fires only when TF1 direction == TF2 direction     |
//|                                                                  |
//|  PRICE GATE (when InpFibZoneEnable=true):                        |
//|   Primary : price within fib 0–0.382 (BUY) / 0.618–∞ (SELL)   |
//|   Fallback: SBR/RBS level ± 0.25×ATR with rejection candle      |
//|             Level expires after InpRetestWindow TF1 bars         |
//|  PRICE GATE (when InpFibZoneEnable=false):                       |
//|   Pure stochastic – K/D cross + TF2 agreement only              |
//|                                                                  |
//|  SBR: broken swing low retested as resistance → SELL             |
//|  RBS: broken swing high retested as support   → BUY             |
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
input ENUM_TIMEFRAMES InpTF2 = PERIOD_M15;   // TF2 – direction (slower)

input group "══════ Stochastic – TF1 (trigger) ══════"
input int    InpStoch_K    = 26;
input int    InpStoch_D    = 7;
input int    InpStoch_Slow = 11;

input group "══════ Stochastic – TF2 (direction) ══════"
input int    InpStoch_K2    = 14;
input int    InpStoch_D2    = 3;
input int    InpStoch_Slow2 = 9;

input group "══════ OB / OS Levels ══════"
input double InpOB_Level     = 80.0;
input double InpOS_Level     = 20.0;
input double InpOBStuckLevel = 90.0;  // Block signals when TF2 K >= this (price grinding OB – wait for retrace)
input double InpOSStuckLevel = 10.0;  // Block signals when TF2 K <= this (price grinding OS – wait for retrace)

input group "══════ Cross Zone Filter (both TFs) ══════"
input double InpSellMinK = 70.0;  // SELL cross valid only if K >= this (OB or near-OB pullback)
input double InpBuyMaxK  = 40.0;  // BUY  cross valid only if K <= this (OS or near-OS bounce)

input group "══════ Signal Cooldown ══════"
input int    InpSignalCooldownMin  = 60;
input int    InpTF2DirTimeoutHrs   = 48;  // TF2 direction expires after N hours without a fresh OB/OS cross (0 = never)

input group "══════ Fib Zone Filter ══════"
input ENUM_TIMEFRAMES InpFibTF         = PERIOD_M30;
input int             InpFibLookback   = 50;
input bool            InpFibZoneEnable  = true;   // Enable fib zone gate for entries
input bool            InpFibGateOnStoch = false;  // Also require fib zone when TF1+TF2 stoch agree (default off)
input double          InpFibBuyZoneMax  = 0.382;
input double          InpFibSellZoneMin = 0.618;

input group "══════ SBR / RBS Rejection ══════"
input int    InpRetestWindow      = 50;   // Max TF1 bars after break to accept retest
input int    InpATRPeriod         = 14;   // ATR period for zone width (0.25 × ATR)
input int    InpRejectionLookback = 5;

input group "══════ Swing Break Signal ══════"
input bool   InpSwingBreakEnable = true;  // Fire BUY/SELL SWING BREAK alert on swing break
input int    InpSwingBreakBars   = 1;     // FibTF bars to hold after break before alerting (0=immediate)

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
int g_h_atr     = INVALID_HANDLE;

// TF bar guards
datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

// TF2 direction – set by OB/OS crosses only; expires after InpTF2DirTimeoutHrs
int      g_tf2_dir      = SIG_NONE;
datetime g_tf2_dir_time = 0;   // Bar time when g_tf2_dir was last set

// Cooldown
int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;

// Fib anchor
double   g_fibSwingHigh = 0.0, g_fibSwingLow  = 0.0;
double   g_oldSwingHigh = 0.0, g_oldSwingLow  = 0.0;
bool     g_hasOldHigh   = false, g_hasOldLow  = false;
datetime g_oldLowBreakTime  = 0;   // FibTF bar time when swing LOW was broken
datetime g_oldHighBreakTime = 0;   // FibTF bar time when swing HIGH was broken
int      g_trendBias    = 0;   // +1=uptrend, -1=downtrend
datetime g_fibBar       = 0;

// Live K – silent tracking
double g_liveK_1 = 0.0, g_liveK_2 = 0.0;

// Swing break pending confirmation
int      g_pendingBreakDir   = SIG_NONE;
datetime g_pendingBreakTime  = 0;
double   g_pendingBreakLevel = 0.0;

//+------------------------------------------------------------------+
//  OnInit
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1 = g_lastBar_2 = 0;
   g_tf2_dir      = SIG_NONE;
   g_tf2_dir_time = 0;
   g_lastCooldownSig  = SIG_NONE;
   g_lastCooldownTime = 0;
   g_fibSwingHigh = g_fibSwingLow = 0.0;
   g_oldSwingHigh = g_oldSwingLow = 0.0;
   g_hasOldHigh       = g_hasOldLow      = false;
   g_oldLowBreakTime  = g_oldHighBreakTime = 0;
   g_trendBias        = 0;
   g_fibBar           = 0;
   g_liveK_1          = g_liveK_2        = 0.0;
   g_pendingBreakDir  = SIG_NONE;
   g_pendingBreakTime = 0;
   g_pendingBreakLevel= 0.0;

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

   g_h_atr = iATR(_Symbol, InpTF1, InpATRPeriod);
   if(g_h_atr == INVALID_HANDLE)
   { Alert("StochFib: Failed ATR handle"); return INIT_FAILED; }

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
   if(g_h_atr     != INVALID_HANDLE) IndicatorRelease(g_h_atr);
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
//  CheckSwingBreakConfirm – fire alert once N FibTF bars have held
//  after a swing break; cancels silently if price recovers.
//+------------------------------------------------------------------+
void CheckSwingBreakConfirm()
{
   if(!InpSwingBreakEnable)          return;
   if(g_pendingBreakDir == SIG_NONE) return;

   datetime barTimes[2];
   if(CopyTime(_Symbol, InpFibTF, 0, 2, barTimes) < 2) return;
   datetime curBar = barTimes[1];

   int barsSince = (int)MathRound((double)(curBar - g_pendingBreakTime) / PeriodSeconds(InpFibTF));
   if(barsSince < InpSwingBreakBars) return;

   double cls[1];
   if(CopyClose(_Symbol, InpFibTF, 1, 1, cls) < 1) return;
   double closePrice = cls[0];

   // Cancel if price has recovered back through the broken level
   if(g_pendingBreakDir == SIG_SELL && closePrice >= g_pendingBreakLevel)
   {
      Print("[SWING BREAK CANCEL] SELL – price recovered above ",
            DoubleToString(g_pendingBreakLevel, _Digits));
      g_pendingBreakDir = SIG_NONE; g_pendingBreakTime = 0;
      return;
   }
   if(g_pendingBreakDir == SIG_BUY && closePrice <= g_pendingBreakLevel)
   {
      Print("[SWING BREAK CANCEL] BUY – price recovered below ",
            DoubleToString(g_pendingBreakLevel, _Digits));
      g_pendingBreakDir = SIG_NONE; g_pendingBreakTime = 0;
      return;
   }

   string dir   = (g_pendingBreakDir == SIG_BUY) ? "BUY"  : "SELL";
   string emoji = (g_pendingBreakDir == SIG_BUY) ? "🔵"   : "🟠";
   string msg   = emoji + " " + dir + " SWING BREAK"
                + "  " + _Symbol
                + "  Level:" + DoubleToString(g_pendingBreakLevel, _Digits)
                + "  Close:" + DoubleToString(closePrice, _Digits)
                + "  [" + IntegerToString(barsSince) + "bar hold on " + TFName(InpFibTF) + "]";

   if(InpEnablePush  && !SendNotification(msg)) Print("Push failed.");
   if(InpEnablePopup) Alert(msg);
   if(InpEnablePrint) Print(msg);

   g_pendingBreakDir  = SIG_NONE;
   g_pendingBreakTime = 0;
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes – main dispatch
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   UpdateFibSwing();
   CheckSwingBreakConfirm();
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
   return "SF_" + _Symbol + "_" + TFName(InpFibTF)
          + "_K" + IntegerToString(InpStoch_K) + "_" + suffix;
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
   GlobalVariableSet(GVName("OHT"), (double)g_oldHighBreakTime);
   GlobalVariableSet(GVName("OLT"), (double)g_oldLowBreakTime);
   GlobalVariableSet(GVName("TRB"), (double)g_trendBias);
   GlobalVariableSet(GVName("TD2"), (double)g_tf2_dir);
   GlobalVariableSet(GVName("T2T"), (double)g_tf2_dir_time);
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
   GlobalVariableGet(GVName("HOH"), hoh); g_hasOldHigh       = (hoh > 0.5);
   GlobalVariableGet(GVName("HOL"), hol); g_hasOldLow        = (hol > 0.5);
   double oht = 0, olt = 0;
   GlobalVariableGet(GVName("OHT"), oht); g_oldHighBreakTime = (datetime)oht;
   GlobalVariableGet(GVName("OLT"), olt); g_oldLowBreakTime  = (datetime)olt;
   GlobalVariableGet(GVName("TRB"), trb); g_trendBias        = (int)MathRound(trb);
   GlobalVariableGet(GVName("TD2"), td2); g_tf2_dir          = (int)MathRound(td2);
   double t2t = 0;
   GlobalVariableGet(GVName("T2T"), t2t); g_tf2_dir_time     = (datetime)t2t;

   // Immediately expire stale direction on load (protects against terminal-restart staleness)
   if(InpTF2DirTimeoutHrs > 0 && g_tf2_dir != SIG_NONE && g_tf2_dir_time > 0)
   {
      int ageSecs = (int)(TimeCurrent() - g_tf2_dir_time);
      if(ageSecs > InpTF2DirTimeoutHrs * 3600)
      {
         Print("[TF2 EXPIRE on load] dir=", (g_tf2_dir == SIG_BUY ? "BUY" : "SELL"),
               " was ", ageSecs / 3600, "h old (limit ", InpTF2DirTimeoutHrs, "h) – reset to NONE");
         g_tf2_dir      = SIG_NONE;
         g_tf2_dir_time = 0;
      }
   }

   Print("[FIB] Restored: High=", DoubleToString(g_fibSwingHigh, _Digits),
         "  Low=",  DoubleToString(g_fibSwingLow,  _Digits),
         "  SBR:", (g_hasOldLow  ? DoubleToString(g_oldSwingLow,  _Digits) : "none"),
         "  RBS:", (g_hasOldHigh ? DoubleToString(g_oldSwingHigh, _Digits) : "none"),
         "  TrendBias:", (g_trendBias == 1 ? "UP" : g_trendBias == -1 ? "DOWN" : "none"),
         "  TF2dir:", (g_tf2_dir == SIG_BUY ? "BUY" : g_tf2_dir == SIG_SELL ? "SELL" : "none"),
         (g_tf2_dir != SIG_NONE ? "  set " + IntegerToString((int)(TimeCurrent() - g_tf2_dir_time) / 3600) + "h ago" : ""));
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

   // Swing LOW broken → old low becomes SBR; invalidate stale RBS; rescan both anchors
   if(close < g_fibSwingLow)
   {
      g_oldSwingLow      = g_fibSwingLow;
      g_hasOldLow        = true;
      g_hasOldHigh       = false;   // bearish breakout invalidates prior RBS level
      g_oldSwingHigh     = 0.0;
      g_oldHighBreakTime = 0;
      g_trendBias        = -1;
      datetime bTimes[1];
      if(CopyTime(_Symbol, InpFibTF, 1, 1, bTimes) == 1) g_oldLowBreakTime = bTimes[0];
      int loIdx = iLowest (_Symbol, InpFibTF, MODE_LOW,  InpFibLookback, 1);
      int hiIdx = iHighest(_Symbol, InpFibTF, MODE_HIGH, InpFibLookback, 1);
      if(loIdx >= 0) g_fibSwingLow  = iLow (_Symbol, InpFibTF, loIdx);
      if(hiIdx >= 0) g_fibSwingHigh = iHigh(_Symbol, InpFibTF, hiIdx);
      double newRange = g_fibSwingHigh - g_fibSwingLow;
      if(newRange < 10 * _Point)
      { Print("[FIB WARN] Post-break range degenerate – skipping re-anchor"); return; }
      Print("[FIB] Swing LOW broken → range=[", DoubleToString(g_fibSwingLow, _Digits),
            ",", DoubleToString(g_fibSwingHigh, _Digits), "]",
            "  SBR level=", DoubleToString(g_oldSwingLow, _Digits));
      g_pendingBreakDir   = SIG_SELL;
      g_pendingBreakTime  = g_fibBar;
      g_pendingBreakLevel = g_oldSwingLow;
      SaveFibState();
   }
   // Swing HIGH broken → old high becomes RBS; invalidate stale SBR; rescan both anchors
   else if(close > g_fibSwingHigh)
   {
      g_oldSwingHigh    = g_fibSwingHigh;
      g_hasOldHigh      = true;
      g_hasOldLow       = false;   // bullish breakout invalidates prior SBR level
      g_oldSwingLow     = 0.0;
      g_oldLowBreakTime = 0;
      g_trendBias       = +1;
      datetime bTimes[1];
      if(CopyTime(_Symbol, InpFibTF, 1, 1, bTimes) == 1) g_oldHighBreakTime = bTimes[0];
      int hiIdx = iHighest(_Symbol, InpFibTF, MODE_HIGH, InpFibLookback, 1);
      int loIdx = iLowest (_Symbol, InpFibTF, MODE_LOW,  InpFibLookback, 1);
      if(hiIdx >= 0) g_fibSwingHigh = iHigh(_Symbol, InpFibTF, hiIdx);
      if(loIdx >= 0) g_fibSwingLow  = iLow (_Symbol, InpFibTF, loIdx);
      double newRange = g_fibSwingHigh - g_fibSwingLow;
      if(newRange < 10 * _Point)
      { Print("[FIB WARN] Post-break range degenerate – skipping re-anchor"); return; }
      Print("[FIB] Swing HIGH broken → range=[", DoubleToString(g_fibSwingLow, _Digits),
            ",", DoubleToString(g_fibSwingHigh, _Digits), "]",
            "  RBS level=", DoubleToString(g_oldSwingHigh, _Digits));
      g_pendingBreakDir   = SIG_BUY;
      g_pendingBreakTime  = g_fibBar;
      g_pendingBreakLevel = g_oldSwingHigh;
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
      return (fibPos >= InpFibSellZoneMin);  // allow > 1.0 (price extended above swing high)
}

//+------------------------------------------------------------------+
//  CheckSBRRBS – direction-enforced role-flip zone check
//  SBR: SELL only – price testing old swing low (broken support → resistance)
//  RBS: BUY  only – price testing old swing high (broken resistance → support)
//+------------------------------------------------------------------+
bool CheckSBRRBS(int sigType, double &fibPos, string &roleTag, double &levelPrice)
{
   fibPos = -1.0; roleTag = ""; levelPrice = 0.0;

   double range = g_fibSwingHigh - g_fibSwingLow;
   if(range <= 0.0) return false;

   // ATR-based zone half-width
   double atrBuf[1];
   if(CopyBuffer(g_h_atr, 0, 1, 1, atrBuf) < 1 || atrBuf[0] <= 0) return false;
   double zoneHalf = 0.5 * atrBuf[0];  // 0.5×ATR gives a wider retest capture zone

   // Window in FibTF bars – the level lives on FibTF so the timer should too.
   // 50 × M30 = 25 hours; far more appropriate than 50 × M5 = 4 hours.
   datetime fibTimes[1];
   datetime curTime = (CopyTime(_Symbol, InpFibTF, 1, 1, fibTimes) == 1)
                      ? fibTimes[0] : TimeCurrent();
   int windowSecs = InpRetestWindow * (int)PeriodSeconds(InpFibTF);

   double cls[1];
   double price = (CopyClose(_Symbol, InpTF1, 1, 1, cls) == 1)
                  ? cls[0]
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(IsBearish(sigType) && g_hasOldLow)
   {
      if(g_oldLowBreakTime > 0 && (curTime - g_oldLowBreakTime) > windowSecs)
      {
         Print("[SBR STALE] Expired after ",
               (int)((curTime - g_oldLowBreakTime) / PeriodSeconds(InpFibTF)),
               " ", TFName(InpFibTF), " bars – clearing");
         g_hasOldLow       = false;
         g_oldSwingLow     = 0.0;
         g_oldLowBreakTime = 0;
         SaveFibState();
      }
      else
      {
         double zoneLo = g_oldSwingLow - zoneHalf;
         double zoneHi = g_oldSwingLow + zoneHalf;
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
   }

   if(IsBullish(sigType) && g_hasOldHigh)
   {
      if(g_oldHighBreakTime > 0 && (curTime - g_oldHighBreakTime) > windowSecs)
      {
         Print("[RBS STALE] Expired after ",
               (int)((curTime - g_oldHighBreakTime) / PeriodSeconds(InpFibTF)),
               " ", TFName(InpFibTF), " bars – clearing");
         g_hasOldHigh       = false;
         g_oldSwingHigh     = 0.0;
         g_oldHighBreakTime = 0;
         SaveFibState();
      }
      else
      {
         double zoneLo = g_oldSwingHigh - zoneHalf;
         double zoneHi = g_oldSwingHigh + zoneHalf;
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

   double atrBuf[1];
   double priceTol;
   if(CopyBuffer(g_h_atr, 0, 1, 1, atrBuf) == 1 && atrBuf[0] > 0)
      priceTol = 0.25 * atrBuf[0];
   else
   {
      Print("[ATR WARN] CopyBuffer failed in HasRejectionCandle – using price fallback");
      priceTol = MathAbs(levelPrice) * 0.001;
   }

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
void FireSignal(int sigType, double fibPos, string fibTag, string tf1Zone = "")
{
   double entry = (sigType == SIG_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp1, tp2, tp3;
   CalcTPSL(sigType, entry, sl, tp1, tp2, tp3);

   bool   isMid  = (tf1Zone == "nearOB" || tf1Zone == "nearOS");
   string sigName = SignalTypeName(sigType) + (isMid ? " AGAIN" : "");

   string emoji  = IsBullish(sigType) ? "🟢" : "🔴";
   string tag    = fibTag == "" ? "" : " (" + fibTag + ")";

   string msg = emoji + " " + sigName + tag
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

   // Expire stale direction: if no fresh OB/OS cross in InpTF2DirTimeoutHrs, reset to NONE.
   if(InpTF2DirTimeoutHrs > 0 && g_tf2_dir != SIG_NONE && g_tf2_dir_time > 0)
   {
      int ageSecs = (int)(barTimes[1] - g_tf2_dir_time);
      if(ageSecs > InpTF2DirTimeoutHrs * 3600)
      {
         Print("[TF2 EXPIRE] dir=", (g_tf2_dir == SIG_BUY ? "BUY" : "SELL"),
               " expired after ", ageSecs / 3600, "h (limit ", InpTF2DirTimeoutHrs, "h) – reset to NONE");
         g_tf2_dir      = SIG_NONE;
         g_tf2_dir_time = 0;
         SaveFibState();
      }
   }

   double k_buf[3];
   double d_buf[3];
   if(CopyBuffer(g_h_stoch_2, MAIN_LINE,   0, 3, k_buf) < 3) return;
   if(CopyBuffer(g_h_stoch_2, SIGNAL_LINE, 0, 3, d_buf) < 3) return;

   double k1 = k_buf[1], d1 = d_buf[1];
   double k2 = k_buf[2], d2 = d_buf[2];

   bool crossUp   = (k2 <= d2) && (k1 > d1);
   bool crossDown = (k2 >= d2) && (k1 < d1);
   if(!crossUp && !crossDown) return;

   // TF2 direction: reversal crosses only (OB/near-OB for SELL, OS/near-OS for BUY).
   // OB cont (crossUp K>80) and OS cont (crossDown K<20) are excluded –
   // they cause rapid direction flips when price grinds in extremes.
   if(crossDown && k1 >= InpSellMinK)
   {
      string zone = (k1 >= InpOB_Level) ? "OB" : "nearOB";
      g_tf2_dir      = SIG_SELL;
      g_tf2_dir_time = barTimes[1];
      Print("[TF2 DIR] → SELL from ", zone, "  K=", DoubleToString(k1, 2));
      SaveFibState();
   }
   else if(crossUp && k1 <= InpBuyMaxK)
   {
      string zone = (k1 <= InpOS_Level) ? "OS" : "nearOS";
      g_tf2_dir      = SIG_BUY;
      g_tf2_dir_time = barTimes[1];
      Print("[TF2 DIR] → BUY from ", zone, "  K=", DoubleToString(k1, 2));
      SaveFibState();
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

   // Read stoch buffers early – needed by both SBR/RBS structural path and stoch path
   double k_buf[3], d_buf[3];
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE,   0, 3, k_buf) < 3) return;
   if(CopyBuffer(g_h_stoch_1, SIGNAL_LINE, 0, 3, d_buf) < 3) return;

   double k1 = k_buf[1], d1 = d_buf[1];
   double k2 = k_buf[2], d2 = d_buf[2];

   bool crossUp   = (k2 <= d2) && (k1 > d1);
   bool crossDown = (k2 >= d2) && (k1 < d1);
   if(!crossUp && !crossDown) return;

   int tf1sig = crossUp ? SIG_BUY : SIG_SELL;

   // ── Structural SBR/RBS path ──
   // Fires when price retests a broken structural level with a rejection candle.
   // TF2 must NOT actively oppose: RBS BUY allowed when TF2 is BUY or NONE;
   // SBR SELL allowed when TF2 is SELL or NONE. Prevents trading against live TF2 bias.
   if(InpFibZoneEnable)
   {
      bool tf2Compatible = (tf1sig == SIG_BUY) ? (g_tf2_dir != SIG_SELL)
                                                : (g_tf2_dir != SIG_BUY);
      bool tf2NotStuck   = (tf1sig == SIG_SELL) ? (g_liveK_2 < InpOBStuckLevel)
                                                 : (g_liveK_2 > InpOSStuckLevel);
      double sbrPos = -1.0; string sbrTag = ""; double sbrLevel = 0.0;
      if(tf2Compatible && tf2NotStuck
         && CheckSBRRBS(tf1sig, sbrPos, sbrTag, sbrLevel)
         && HasRejectionCandle(IsBearish(tf1sig), sbrLevel, InpTF1, InpRejectionLookback)
         && PassesCooldown(tf1sig, barTimes[1]))
      {
         Print("[", sbrTag, "] ", SignalTypeName(tf1sig),
               "  K=", DoubleToString(k1, 1),
               "  level=", DoubleToString(sbrLevel, _Digits),
               "  TF2=", (g_tf2_dir == SIG_BUY ? "BUY" : g_tf2_dir == SIG_SELL ? "SELL" : "none"));
         FireSignal(tf1sig, sbrPos, sbrTag, "");
         g_lastCooldownSig  = tf1sig;
         g_lastCooldownTime = barTimes[1];
         return;  // one signal per bar
      }
      else if(InpEnablePrint)
      {
         if(!tf2Compatible)
            Print("[SBR/RBS SKIP] TF2 actively opposes: tf1sig=", SignalTypeName(tf1sig),
                  " TF2=", (g_tf2_dir == SIG_BUY ? "BUY" : "SELL"));
         else if(!tf2NotStuck)
            Print("[SBR/RBS SKIP] TF2 K stuck: tf1sig=", SignalTypeName(tf1sig),
                  " TF2 K=", DoubleToString(g_liveK_2, 1),
                  (tf1sig == SIG_SELL ? " >= " : " <= "),
                  (tf1sig == SIG_SELL ? InpOBStuckLevel : InpOSStuckLevel));
      }
   }

   // ── Standard stochastic path: requires TF2 direction agreement ──
   if(g_tf2_dir == SIG_NONE) return;  // no TF2 direction established yet

   // TF1 zone filter: block mid-zone (InpBuyMaxK – InpSellMinK) crosses
   // SELL valid: K >= InpSellMinK (OB/near-OB reversal) OR K <= InpOS_Level (OS continuation)
   // BUY  valid: K <= InpBuyMaxK  (OS/near-OS bounce)   OR K >= InpOB_Level (OB continuation)
   bool tf1SellOk = (k1 >= InpSellMinK) || (k1 <= InpOS_Level);
   bool tf1BuyOk  = (k1 <= InpBuyMaxK)  || (k1 >= InpOB_Level);

   if(tf1sig == SIG_SELL && !tf1SellOk)
   {
      Print("[TF1 NOISE] SELL cross K=", DoubleToString(k1, 1),
            " in noise band (", InpOS_Level, "–", InpSellMinK, ") – ignored");
      return;
   }
   if(tf1sig == SIG_BUY && !tf1BuyOk)
   {
      Print("[TF1 NOISE] BUY cross K=", DoubleToString(k1, 1),
            " in noise band (", InpBuyMaxK, "–", InpOB_Level, ") – ignored");
      return;
   }

   // Zone label for signal quality context in message
   string tf1Zone;
   if(crossUp)
      tf1Zone = (k1 <= InpOS_Level) ? "OS" : (k1 <= InpBuyMaxK ? "nearOS" : "OB cont");
   else
      tf1Zone = (k1 >= InpOB_Level) ? "OB" : (k1 >= InpSellMinK ? "nearOB" : "OS cont");

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

   // Stuck OB/OS: TF2 K is grinding at extreme – market is trending, not reversing.
   // Block and wait for K to retrace below InpOBStuckLevel / above InpOSStuckLevel.
   if(tf1sig == SIG_SELL && g_liveK_2 >= InpOBStuckLevel)
   {
      Print("[OB STUCK] SELL blocked – TF2 K=", DoubleToString(g_liveK_2, 1),
            " >= ", InpOBStuckLevel, "  wait for retrace");
      return;
   }
   if(tf1sig == SIG_BUY && g_liveK_2 <= InpOSStuckLevel)
   {
      Print("[OS STUCK] BUY blocked – TF2 K=", DoubleToString(g_liveK_2, 1),
            " <= ", InpOSStuckLevel, "  wait for retrace");
      return;
   }

   // Cooldown check – before any fib/SBR computation
   if(!PassesCooldown(tf1sig, barTimes[1]))
   {
      Print("[COOLDOWN] ", SignalTypeName(tf1sig), " blocked – within ", InpSignalCooldownMin, "min");
      return;
   }

   // Fib zone gate – optional on stoch path. Off by default (InpFibGateOnStoch=false):
   // TF1+TF2 stoch agreement is sufficient; structural trades use the independent SBR/RBS path.
   // Enable InpFibGateOnStoch=true to also require price to be in a fib zone here.
   double fibPos = -1.0; string fibTag = "";
   if(InpFibZoneEnable && InpFibGateOnStoch)
   {
      bool zonePassed = (tf1Zone == "OS cont" || tf1Zone == "OB cont")
                        || CheckFibZone(tf1sig, fibPos, fibTag);
      if(!zonePassed)
      {
         double range = g_fibSwingHigh - g_fibSwingLow;
         double lp    = (range > 0)
                        ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - g_fibSwingLow) / range
                        : -1.0;
         Print("[FIB BLOCK] ", SignalTypeName(tf1sig),
               " blocked  fib=", DoubleToString(lp, 3), " K=", DoubleToString(k1, 1));
         return;
      }
   }

   FireSignal(tf1sig, fibPos, fibTag, tf1Zone);

   g_lastCooldownSig  = tf1sig;
   g_lastCooldownTime = barTimes[1];
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
