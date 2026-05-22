//+------------------------------------------------------------------+
//|                   StochFib_MTF_Alert.mq5                         |
//|  Dual-TF Stochastic + Dynamic Fib Zone Gate + EMA Cross Signal   |
//|  v1.0                                                            |
//|                                                                  |
//|  SIGNAL LOGIC (TF1 – strict):                                    |
//|   BUY  – K crosses D UP   AND K touched OS within N bars         |
//|           AND price in fib 0 → 0.382 zone                       |
//|   SELL – K crosses D DOWN AND K touched OB within N bars         |
//|           AND price in fib 0.618 → 1 zone                       |
//|                                                                  |
//|  STAGE 1: TF1 arms → 🟢/🔴 BUY/SELL RISKY @ FIB x.xxx         |
//|  STAGE 2: TF2 confirms → 🟢/🔴 BUY/SELL SAFE @ FIB x.xxx      |
//|           with SL at swing + TP1/TP2/TP3 via R:R                |
//|                                                                  |
//|  SBR tag: price near old swing low after break (was support)     |
//|  RBS tag: price near old swing high after break (was resistance) |
//|                                                                  |
//|  EMA CROSS: independent secondary signal (re-entry replacement)  |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "1.00"
#property description "Stoch + Fib zone gate + EMA cross – dual independent signal streams"
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
input group "══════ Stochastic Settings – TF1 ══════"
input int    InpStoch_K    = 50;
input int    InpStoch_D    = 7;
input int    InpStoch_Slow = 11;

input group "══════ Stochastic Settings – TF2 Override ══════"
input bool   InpTF2UseOwnStoch = true;
input int    InpStoch_K2       = 24;
input int    InpStoch_D2       = 3;
input int    InpStoch_Slow2    = 9;

input group "══════ OB / OS Levels ══════"
input double InpOB_Level   = 80.0;
input double InpOS_Level   = 20.0;
input int    InpOSLookback = 20;

input group "══════ Signal Cooldown ══════"
input int    InpSignalCooldownMin = 60;

input group "══════ EMA Cross Signal (independent) ══════"
input bool            InpEMACrossEnable = true;
input ENUM_TIMEFRAMES InpEMACross_TF    = PERIOD_M5;
input int             InpMA_Period      = 34;
input int             InpMA_Period2     = 9;
input ENUM_MA_METHOD  InpMA_Method      = MODE_EMA;

input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1            = PERIOD_M5;
input bool            InpEnableTF1      = true;
input ENUM_TIMEFRAMES InpTF2            = PERIOD_M15;
input bool            InpEnableTF2      = true;
input bool            InpTF2StrictZones = false;

input group "══════ Fib Zone Filter ══════"
input ENUM_TIMEFRAMES InpFibTF          = PERIOD_M30;   // TF for swing high/low detection
input int             InpFibLookback    = 100;           // Bars to scan for swing anchor
input double          InpFibBuyZoneMax  = 0.382;         // BUY zone upper bound (0 → this)
input double          InpFibSellZoneMin = 0.618;         // SELL zone lower bound (this → 1)
input double          InpSBR_Tol        = 0.05;          // Proximity band for SBR/RBS tag (% of range)

input group "══════ TP / SL Targets ══════"
input int    InpSLLookback  = 20;
input int    InpSLFallback  = 500;  // Fallback SL distance in points if swing history insufficient
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
// Indicator handles
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;
int g_h_ma_slow = INVALID_HANDLE;  // EMA(InpMA_Period)  on InpEMACross_TF – slow side of cross
int g_h_ma_fast = INVALID_HANDLE;  // EMA(InpMA_Period2) on InpEMACross_TF – fast side of cross

// TF state
datetime g_lastBar_1 = 0, g_lastBar_2 = 0;
int      g_state_1   = SIG_NONE, g_state_2 = SIG_NONE;
datetime g_bar_1     = 0, g_bar_2 = 0;
datetime g_fired_bar_1 = 0, g_fired_bar_2 = 0;

// Cooldown
int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;

// EMA cross bar guard
datetime g_lastMACrossBar = 0;

// Fib anchor
double   g_fibSwingHigh = 0.0, g_fibSwingLow  = 0.0;
double   g_oldSwingHigh = 0.0, g_oldSwingLow  = 0.0;
bool     g_hasOldHigh   = false, g_hasOldLow  = false;
datetime g_fibBar       = 0;

// RISKY-fired tracking – SAFE only fires when RISKY preceded it
bool     g_riskyBuyFired  = false, g_riskySellFired  = false;
string   g_riskyBuyTag    = "",    g_riskySellTag    = "";
double   g_riskyBuyFibPos = 0.0,  g_riskySellFibPos = 0.0;

//+------------------------------------------------------------------+
//  OnInit
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1 = g_lastBar_2 = 0;
   g_state_1 = g_state_2 = SIG_NONE;
   g_bar_1   = g_bar_2   = 0;
   g_fired_bar_1 = g_fired_bar_2 = 0;
   g_lastCooldownSig  = SIG_NONE;
   g_lastCooldownTime = 0;
   g_lastMACrossBar   = 0;
   g_fibSwingHigh = g_fibSwingLow = 0.0;
   g_oldSwingHigh = g_oldSwingLow = 0.0;
   g_hasOldHigh   = g_hasOldLow  = false;
   g_fibBar       = 0;
   g_riskyBuyFired = g_riskySellFired = false;

   // Restore fib state from last session (survives MT5 restarts)
   LoadFibState();

   // TF1 stochastic
   if(InpEnableTF1)
   {
      g_h_stoch_1 = iStochastic(_Symbol, InpTF1,
                                 InpStoch_K, InpStoch_D, InpStoch_Slow,
                                 MODE_SMA, STO_LOWHIGH);
      if(g_h_stoch_1 == INVALID_HANDLE)
      { Alert("StochFib: Failed Stoch TF1 handle"); return INIT_FAILED; }
   }

   // TF2 stochastic
   if(InpEnableTF2)
   {
      int k2 = InpTF2UseOwnStoch ? InpStoch_K2    : InpStoch_K;
      int d2 = InpTF2UseOwnStoch ? InpStoch_D2    : InpStoch_D;
      int s2 = InpTF2UseOwnStoch ? InpStoch_Slow2 : InpStoch_Slow;
      g_h_stoch_2 = iStochastic(_Symbol, InpTF2, k2, d2, s2, MODE_SMA, STO_LOWHIGH);
      if(g_h_stoch_2 == INVALID_HANDLE)
      { Alert("StochFib: Failed Stoch TF2 handle"); return INIT_FAILED; }
   }

   // Both EMA handles on InpEMACross_TF – fixes cross-TF mismatch
   if(InpEMACrossEnable)
   {
      g_h_ma_slow = iMA(_Symbol, InpEMACross_TF, InpMA_Period,  0, InpMA_Method, PRICE_CLOSE);
      g_h_ma_fast = iMA(_Symbol, InpEMACross_TF, InpMA_Period2, 0, InpMA_Method, PRICE_CLOSE);
      if(g_h_ma_slow == INVALID_HANDLE || g_h_ma_fast == INVALID_HANDLE)
      { Alert("StochFib: Failed EMA handles"); return INIT_FAILED; }
   }

   EventSetTimer(2);

   int tf2K = InpTF2UseOwnStoch ? InpStoch_K2    : InpStoch_K;
   int tf2D = InpTF2UseOwnStoch ? InpStoch_D2    : InpStoch_D;
   int tf2S = InpTF2UseOwnStoch ? InpStoch_Slow2 : InpStoch_Slow;
   Print("StochFib v1.0 loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1), " Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | TF2:", TFName(InpTF2), " Stoch(", tf2K, ",", tf2D, ",", tf2S, ")",
         " | FibTF:", TFName(InpFibTF), " Lookback:", InpFibLookback,
         " BuyZone:0→", InpFibBuyZoneMax, " SellZone:", InpFibSellZoneMin, "→1",
         " | EMA cross:", TFName(InpEMACross_TF), " EMA", InpMA_Period2, "/EMA", InpMA_Period);

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
   if(g_h_ma_slow != INVALID_HANDLE) IndicatorRelease(g_h_ma_slow);
   if(g_h_ma_fast != INVALID_HANDLE) IndicatorRelease(g_h_ma_fast);
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
//  CheckAllTimeframes – main dispatch
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   UpdateFibSwing();
   CheckMACross();

   if(!InpEnableTF1) return;

   bool changed1 = ProcessTimeframe(InpTF1, g_h_stoch_1,
                                    g_lastBar_1, g_state_1, g_bar_1, true);

   bool changed2 = false;
   if(InpEnableTF2)
      changed2 = ProcessTimeframe(InpTF2, g_h_stoch_2,
                                  g_lastBar_2, g_state_2, g_bar_2, InpTF2StrictZones);

   // TF1 state changed → attempt RISKY (fib zone gated)
   if(changed1 && g_state_1 != SIG_NONE)
   {
      // Cancel any pending RISKY in the opposite direction
      if(IsBullish(g_state_1)) g_riskySellFired = false;
      if(IsBearish(g_state_1)) g_riskyBuyFired  = false;

      double fibPos; string fibTag;
      if(CheckFibZone(g_state_1, fibPos, fibTag))
      {
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         FireArmedAlert(g_state_1, price, fibPos, fibTag);
         if(IsBullish(g_state_1))
         { g_riskyBuyFired  = true; g_riskyBuyTag  = fibTag; g_riskyBuyFibPos  = fibPos; }
         else
         { g_riskySellFired = true; g_riskySellTag = fibTag; g_riskySellFibPos = fibPos; }
      }
      else
         Print("[FIB BLOCK] RISKY ", SignalTypeName(g_state_1),
               " blocked – fibPos=", DoubleToString(fibPos,3));
   }

   if(changed1 || changed2)
      CheckConfirmation();
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
//  GlobalVariable key builder – unique per symbol + fib TF
//+------------------------------------------------------------------+
string GVName(string suffix)
{
   return "SF_" + _Symbol + "_" + TFName(InpFibTF) + "_" + suffix;
}

//+------------------------------------------------------------------+
//  SaveFibState – persist fib anchors to GlobalVariables
//+------------------------------------------------------------------+
void SaveFibState()
{
   GlobalVariableSet(GVName("SH"),  g_fibSwingHigh);
   GlobalVariableSet(GVName("SL"),  g_fibSwingLow);
   GlobalVariableSet(GVName("OSH"), g_oldSwingHigh);
   GlobalVariableSet(GVName("OSL"), g_oldSwingLow);
   GlobalVariableSet(GVName("HOH"), g_hasOldHigh ? 1.0 : 0.0);
   GlobalVariableSet(GVName("HOL"), g_hasOldLow  ? 1.0 : 0.0);
}

//+------------------------------------------------------------------+
//  LoadFibState – restore fib anchors from GlobalVariables on restart
//  Returns true if valid saved state was found
//+------------------------------------------------------------------+
bool LoadFibState()
{
   double sh = 0, sl = 0;
   if(!GlobalVariableGet(GVName("SH"), sh)) return false;
   if(!GlobalVariableGet(GVName("SL"), sl)) return false;
   if(sh <= 0 || sl <= 0 || sh <= sl)       return false;

   g_fibSwingHigh = sh;
   g_fibSwingLow  = sl;

   double osh = 0, osl = 0, hoh = 0, hol = 0;
   GlobalVariableGet(GVName("OSH"), osh); g_oldSwingHigh = osh;
   GlobalVariableGet(GVName("OSL"), osl); g_oldSwingLow  = osl;
   GlobalVariableGet(GVName("HOH"), hoh); g_hasOldHigh   = (hoh > 0.5);
   GlobalVariableGet(GVName("HOL"), hol); g_hasOldLow    = (hol > 0.5);

   Print("[FIB] Restored: High=", DoubleToString(g_fibSwingHigh, _Digits),
         "  Low=",  DoubleToString(g_fibSwingLow,  _Digits),
         "  SBR:", (g_hasOldLow  ? DoubleToString(g_oldSwingLow,  _Digits) : "none"),
         "  RBS:", (g_hasOldHigh ? DoubleToString(g_oldSwingHigh, _Digits) : "none"));
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

   // First call: initialise from lookback (only if LoadFibState did not restore)
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

   // Last closed bar close
   double cls[1];
   if(CopyClose(_Symbol, InpFibTF, 1, 1, cls) < 1) return;
   double close = cls[0];

   // Swing LOW broken → old low becomes SBR, anchor resets
   // Note: g_hasOldHigh is NOT cleared — both SBR and RBS can be active simultaneously
   if(close < g_fibSwingLow)
   {
      g_oldSwingLow = g_fibSwingLow;
      g_hasOldLow   = true;
      int loIdx = iLowest(_Symbol, InpFibTF, MODE_LOW, InpFibLookback, 1);
      if(loIdx >= 0) g_fibSwingLow = iLow(_Symbol, InpFibTF, loIdx);
      Print("[FIB] Swing LOW broken → new 0=", DoubleToString(g_fibSwingLow, _Digits),
            "  SBR level=", DoubleToString(g_oldSwingLow, _Digits));
      SaveFibState();
   }
   // Swing HIGH broken → old high becomes RBS, anchor resets
   // Note: g_hasOldLow is NOT cleared — both SBR and RBS can be active simultaneously
   else if(close > g_fibSwingHigh)
   {
      g_oldSwingHigh = g_fibSwingHigh;
      g_hasOldHigh   = true;
      int hiIdx = iHighest(_Symbol, InpFibTF, MODE_HIGH, InpFibLookback, 1);
      if(hiIdx >= 0) g_fibSwingHigh = iHigh(_Symbol, InpFibTF, hiIdx);
      Print("[FIB] Swing HIGH broken → new 1=", DoubleToString(g_fibSwingHigh, _Digits),
            "  RBS level=", DoubleToString(g_oldSwingHigh, _Digits));
      SaveFibState();
   }
}

//+------------------------------------------------------------------+
//  CheckFibZone – gate signals by fib position and tag SBR/RBS
//  Returns true if price is in the valid zone for sigType
//  Populates fibPos (0.0–1.0) and fibTag ("SBR", "RBS", or "")
//+------------------------------------------------------------------+
bool CheckFibZone(int sigType, double &fibPos, string &fibTag)
{
   fibPos = -1.0;
   fibTag = "";

   double range = g_fibSwingHigh - g_fibSwingLow;
   if(range <= 0.0) return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   fibPos = (price - g_fibSwingLow) / range;

   // SBR: price near the old swing low (was support, now resistance after break)
   if(g_hasOldLow && MathAbs(price - g_oldSwingLow) / range <= InpSBR_Tol)
      fibTag = "SBR";

   // RBS: price near the old swing high (was resistance, now support after break)
   if(g_hasOldHigh && MathAbs(price - g_oldSwingHigh) / range <= InpSBR_Tol)
      fibTag = "RBS";

   // Zone gate
   if(IsBullish(sigType))
      return (fibPos >= 0.0 && fibPos <= InpFibBuyZoneMax);
   else
      return (fibPos >= InpFibSellZoneMin && fibPos <= 1.0);
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
      if(risk <= 0) risk = InpSLFallback * _Point;
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
      if(risk <= 0) risk = InpSLFallback * _Point;
      tp1 = entry - risk * InpTP1_RR;
      tp2 = entry - risk * InpTP2_RR;
      tp3 = entry - risk * InpTP3_RR;
   }
}

//+------------------------------------------------------------------+
//  FireArmedAlert – Stage 1 RISKY
//  🟢 BUY RISKY XAUUSD.p @ FIB 0.236  Price:4527.00
//  🟢 BUY RISKY (SBR) XAUUSD.p @ FIB 0.236  Price:4527.00
//+------------------------------------------------------------------+
void FireArmedAlert(int sigType, double price, double fibPos, string fibTag)
{
   string emoji = IsBullish(sigType) ? "🟢" : "🔴";
   string tag   = fibTag == "" ? "" : " (" + fibTag + ")";
   string msg   = emoji + " " + SignalTypeName(sigType) + " RISKY" + tag
                + " " + _Symbol
                + " @ FIB " + FibPosLabel(fibPos)
                + "  Price:" + DoubleToString(price, _Digits);

   if(InpEnablePush && !SendNotification(msg)) Print("Push failed.");
   if(InpEnablePopup) Alert(msg);
   if(InpEnablePrint) Print(msg);
}

//+------------------------------------------------------------------+
//  FireConfirmedAlert – Stage 2 SAFE
//  🟢 BUY SAFE XAUUSD.p @ FIB 0.236  SL:4510  TP1:4544  TP2:4578  TP3:4612
//+------------------------------------------------------------------+
void FireConfirmedAlert(int sigType, double fibPos, string fibTag)
{
   double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp1, tp2, tp3;
   CalcTPSL(sigType, entry, sl, tp1, tp2, tp3);

   string emoji = IsBullish(sigType) ? "🟢" : "🔴";
   string tag   = fibTag == "" ? "" : " (" + fibTag + ")";
   string msg   = emoji + " " + SignalTypeName(sigType) + " SAFE" + tag
                + " " + _Symbol
                + " @ FIB " + FibPosLabel(fibPos)
                + "  SL:"  + DoubleToString(sl,  _Digits)
                + "  TP1:" + DoubleToString(tp1, _Digits)
                + "  TP2:" + DoubleToString(tp2, _Digits)
                + "  TP3:" + DoubleToString(tp3, _Digits);

   if(InpEnablePush && !SendNotification(msg)) Print("Push failed.");
   if(InpEnablePopup) Alert(msg);
   if(InpEnablePrint) Print(msg);
}

//+------------------------------------------------------------------+
//  CheckMACross – independent EMA cross secondary signal
//  Both EMAs on InpEMACross_TF (no cross-TF mismatch)
//+------------------------------------------------------------------+
void CheckMACross()
{
   if(!InpEMACrossEnable) return;
   if(g_h_ma_slow == INVALID_HANDLE || g_h_ma_fast == INVALID_HANDLE) return;

   datetime barTimes[3];
   if(CopyTime(_Symbol, InpEMACross_TF, 0, 3, barTimes) < 3) return;
   if(barTimes[1] == g_lastMACrossBar) return;
   g_lastMACrossBar = barTimes[1];

   double slow[3], fast[3];
   if(CopyBuffer(g_h_ma_slow, 0, 0, 3, slow) < 3) return;
   if(CopyBuffer(g_h_ma_fast, 0, 0, 3, fast) < 3) return;

   bool crossUp   = (fast[2] <= slow[2]) && (fast[1] > slow[1]);
   bool crossDown = (fast[2] >= slow[2]) && (fast[1] < slow[1]);
   if(!crossUp && !crossDown) return;

   string dir    = crossUp ? "BUY" : "SELL";
   string emoji2 = crossUp ? "🟢" : "🔴";
   string msg    = emoji2 + " EMA CROSS " + TFName(InpEMACross_TF) + " " + dir + " " + _Symbol;

   if(InpEnablePush && !SendNotification(msg)) Print("Push failed.");
   if(InpEnablePopup) Alert(msg);
   if(InpEnablePrint) Print(msg);
}

//+------------------------------------------------------------------+
//  ProcessTimeframe – bar-change gated state update
//  Returns true if state changed (does NOT fire alerts)
//+------------------------------------------------------------------+
bool ProcessTimeframe(ENUM_TIMEFRAMES tf, int h_stoch,
                      datetime &lastBar, int &state, datetime &stateBar,
                      bool strictZones)
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, tf, 0, 3, barTimes) < 3) return false;
   if(barTimes[1] == lastBar)                     return false;
   lastBar = barTimes[1];

   int    kCopy = InpOSLookback + 2;
   double k_buf[];
   double d_buf[3];
   ArrayResize(k_buf, kCopy);
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, kCopy, k_buf) < kCopy) return false;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3,     d_buf) < 3)     return false;

   double k1 = k_buf[1], d1 = d_buf[1];  // last closed bar
   double k2 = k_buf[2], d2 = d_buf[2];  // 2 bars ago

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   if(!crossedUp && !crossedDown) return false;

   //--- Loose mode (TF2 default): any cross sets direction
   if(!strictZones)
   {
      if(crossedUp)
      {
         state = SIG_BUY; stateBar = barTimes[1];
         Print("[STATE ", TFName(tf), "] → BUY (confirm K=", DoubleToString(k1,2), " cross UP)");
         return true;
      }
      if(crossedDown)
      {
         state = SIG_SELL; stateBar = barTimes[1];
         Print("[STATE ", TFName(tf), "] → SELL (confirm K=", DoubleToString(k1,2), " cross DN)");
         return true;
      }
      return false;
   }

   //--- Strict mode (TF1): cross must originate from OS/OB zone within lookback
   bool recentlyOS = false, recentlyOB = false;
   for(int i = 1; i < kCopy; i++)
   {
      if(k_buf[i] <= InpOS_Level) recentlyOS = true;
      if(k_buf[i] >= InpOB_Level) recentlyOB = true;
   }

   if(crossedUp && recentlyOS)
   {
      state = SIG_BUY; stateBar = barTimes[1];
      Print("[STATE ", TFName(tf), "] → BUY from OS  K=", DoubleToString(k1,2));
      return true;
   }
   if(crossedDown && recentlyOB)
   {
      state = SIG_SELL; stateBar = barTimes[1];
      Print("[STATE ", TFName(tf), "] → SELL from OB  K=", DoubleToString(k1,2));
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//  CheckConfirmation – TF1 armed + TF2 agrees → fire SAFE
//  SAFE only fires if RISKY was previously fired (fib zone passed)
//+------------------------------------------------------------------+
void CheckConfirmation()
{
   // Single TF mode: treat TF1 state as both armed and confirmed
   if(!InpEnableTF1 || !InpEnableTF2)
   {
      if(InpEnableTF1 && g_state_1 != SIG_NONE && g_bar_1 != g_fired_bar_1)
      {
         if(PassesCooldown(g_state_1, g_bar_1))
         {
            double fibPos; string fibTag;
            if(CheckFibZone(g_state_1, fibPos, fibTag))
            {
               FireConfirmedAlert(g_state_1, fibPos, fibTag);
               g_fired_bar_1      = g_bar_1;
               g_lastCooldownSig  = g_state_1;
               g_lastCooldownTime = g_bar_1;
            }
         }
         else
            Print("[COOLDOWN] ", SignalTypeName(g_state_1), " blocked");
      }
      return;
   }

   if(g_state_1 == SIG_NONE || g_state_2 == SIG_NONE) return;

   bool bullish = IsBullish(g_state_1) && IsBullish(g_state_2);
   bool bearish = IsBearish(g_state_1) && IsBearish(g_state_2);
   if(!bullish && !bearish)
   {
      Print("[WAIT] TF1=", SignalTypeName(g_state_1),
            " TF2=", SignalTypeName(g_state_2), " – direction mismatch");
      return;
   }

   if(g_bar_1 == g_fired_bar_1 && g_bar_2 == g_fired_bar_2) return;

   datetime confirmedTime = MathMax(g_bar_1, g_bar_2);
   if(!PassesCooldown(g_state_1, confirmedTime))
   {
      Print("[COOLDOWN] ", SignalTypeName(g_state_1), " blocked – within ", InpSignalCooldownMin, "min");
      g_fired_bar_1 = g_bar_1;
      g_fired_bar_2 = g_bar_2;
      return;
   }

   // SAFE requires RISKY to have fired first (fib zone must have passed at TF1 stage)
   if(bullish && !g_riskyBuyFired)
   { Print("[FIB BLOCK] SAFE BUY skipped – no RISKY preceded it"); return; }
   if(bearish && !g_riskySellFired)
   { Print("[FIB BLOCK] SAFE SELL skipped – no RISKY preceded it"); return; }

   // Re-check fib zone at confirmation time (price may have moved)
   double fibPos; string fibTag;
   if(!CheckFibZone(g_state_1, fibPos, fibTag))
   {
      Print("[FIB BLOCK] SAFE ", SignalTypeName(g_state_1),
            " blocked at confirmation – fibPos=", DoubleToString(fibPos,3));
      return;
   }

   FireConfirmedAlert(g_state_1, fibPos, fibTag);

   g_fired_bar_1 = g_bar_1;
   g_fired_bar_2 = g_bar_2;
   g_lastCooldownSig  = g_state_1;
   g_lastCooldownTime = confirmedTime;

   // Reset risky flags after SAFE fires
   if(bullish) g_riskyBuyFired  = false;
   if(bearish) g_riskySellFired = false;
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
