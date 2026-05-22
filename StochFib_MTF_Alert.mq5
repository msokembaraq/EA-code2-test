//+------------------------------------------------------------------+
//|                   StochFib_MTF_Alert.mq5                         |
//|  Dual-TF Stochastic + Dynamic Fib Zone Gate + EMA Cross Signal   |
//|  v1.1  – SBR/RBS direction-enforced + rejection candle gate      |
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
#property version     "1.10"
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
input double          InpSBR_Tol          = 0.05;  // ± band around old level for SBR/RBS detection (fraction of range)

input group "══════ SBR / RBS Rejection ══════"
input double          InpSBR_DeepExt      = 0.382; // SBR zone extends this far below old swing-low (fraction of range)
input double          InpRBS_DeepExt      = 0.382; // RBS zone extends this far above old swing-high (fraction of range)
input int             InpRejectionLookback = 5;    // Bars on TF1 to scan for textbook rejection candle

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
double   g_riskyBuyK      = 0.0,  g_riskySellK      = 0.0;  // K at cross time

// Live K – updated every bar for silent tracking
double   g_liveK_1 = 0.0, g_liveK_2 = 0.0;

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
   g_riskyBuyK     = g_riskySellK    = 0.0;
   g_liveK_1       = g_liveK_2       = 0.0;

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
   Print("StochFib v1.1 loaded  ", _Symbol,
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
//  UpdateLiveK – read current (forming-bar) K on both TFs each tick
//+------------------------------------------------------------------+
void UpdateLiveK()
{
   double k[1];
   if(g_h_stoch_1 != INVALID_HANDLE && CopyBuffer(g_h_stoch_1, MAIN_LINE, 0, 1, k) == 1)
      g_liveK_1 = k[0];
   if(g_h_stoch_2 != INVALID_HANDLE && CopyBuffer(g_h_stoch_2, MAIN_LINE, 0, 1, k) == 1)
      g_liveK_2 = k[0];
}

//+------------------------------------------------------------------+
//  SilentWatch – journal-only bar-change state snapshot
//+------------------------------------------------------------------+
void SilentWatch()
{
   if(!InpEnablePrint) return;
   if(g_state_1 == SIG_NONE && !g_riskyBuyFired && !g_riskySellFired) return;

   double range  = g_fibSwingHigh - g_fibSwingLow;
   double price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double fibPos = (range > 0) ? (price - g_fibSwingLow) / range : -1.0;

   string zone = (fibPos >= 0.0 && fibPos <= InpFibBuyZoneMax)   ? "BUY ZONE"  :
                 (fibPos >= InpFibSellZoneMin && fibPos <= 1.0)   ? "SELL ZONE" : "DEAD ZONE";

   string armed = (g_riskyBuyFired  ? "BUY ARMED @FIB " + FibPosLabel(g_riskyBuyFibPos)   + " K_entry=" + DoubleToString(g_riskyBuyK,  1) :
                   g_riskySellFired ? "SELL ARMED @FIB " + FibPosLabel(g_riskySellFibPos) + " K_entry=" + DoubleToString(g_riskySellK, 1) :
                   "no pending");

   Print("[WATCH] ",
         TFName(InpTF1), " K=", DoubleToString(g_liveK_1, 1),
         " | ", TFName(InpTF2), " K=", DoubleToString(g_liveK_2, 1),
         " | fib=", FibPosLabel(fibPos), " (", zone, ")",
         " | ", armed);
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes – main dispatch
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   UpdateFibSwing();
   UpdateLiveK();
   CheckMACross();

   if(!InpEnableTF1) return;

   double crossK1 = 0.0, crossK2 = 0.0;
   bool changed1 = ProcessTimeframe(InpTF1, g_h_stoch_1,
                                    g_lastBar_1, g_state_1, g_bar_1, true, crossK1);

   bool changed2 = false;
   if(InpEnableTF2)
      changed2 = ProcessTimeframe(InpTF2, g_h_stoch_2,
                                  g_lastBar_2, g_state_2, g_bar_2, InpTF2StrictZones, crossK2);

   // TF1 state changed → attempt RISKY (fib zone gated)
   if(changed1 && g_state_1 != SIG_NONE)
   {
      // Cancel any pending RISKY in the opposite direction
      if(IsBullish(g_state_1)) g_riskySellFired = false;
      if(IsBearish(g_state_1)) g_riskyBuyFired  = false;

      double fibPos = -1.0; string fibTag = "";
      bool   zonePassed = false;

      // 1. Normal fib zone: BUY→[0, BuyZoneMax], SELL→[SellZoneMin, 1]
      if(CheckFibZone(g_state_1, fibPos, fibTag))
      {
         zonePassed = true;
      }
      // 2. SBR/RBS: direction-enforced + requires rejection candle on TF1
      else
      {
         double levelPrice;
         if(CheckSBRRBS(g_state_1, fibPos, fibTag, levelPrice))
         {
            if(HasRejectionCandle(IsBearish(g_state_1), levelPrice, InpTF1, InpRejectionLookback))
               zonePassed = true;
            else
               Print("[SBR/RBS BLOCK] No rejection candle at ",
                     DoubleToString(levelPrice, _Digits),
                     " for ", fibTag, " ", SignalTypeName(g_state_1));
         }
      }

      if(zonePassed)
      {
         FireArmedAlert(g_state_1, fibPos, fibTag);
         if(IsBullish(g_state_1))
         { g_riskyBuyFired  = true; g_riskyBuyTag  = fibTag; g_riskyBuyFibPos  = fibPos; g_riskyBuyK  = crossK1; }
         else
         { g_riskySellFired = true; g_riskySellTag = fibTag; g_riskySellFibPos = fibPos; g_riskySellK = crossK1; }
      }
      else
         Print("[FIB BLOCK] RISKY ", SignalTypeName(g_state_1),
               " blocked – fibPos=", DoubleToString(fibPos, 3),
               " K=", DoubleToString(crossK1, 1));
   }

   if(changed1 || changed2)
      CheckConfirmation();

   // Silent bar-change snapshot (only when TF1 bar changed)
   if(changed1 || changed2)
      SilentWatch();
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
//  CheckFibZone – normal zone gate (no role-flip tagging here)
//  BUY:  fibPos in [0, InpFibBuyZoneMax]
//  SELL: fibPos in [InpFibSellZoneMin, 1]
//  SBR/RBS signals handled separately by CheckSBRRBS
//+------------------------------------------------------------------+
bool CheckFibZone(int sigType, double &fibPos, string &fibTag)
{
   fibPos = -1.0;
   fibTag = "";  // normal zone signals carry no role-flip tag

   double range = g_fibSwingHigh - g_fibSwingLow;
   if(range <= 0.0) return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   fibPos = (price - g_fibSwingLow) / range;

   // SBR/RBS direction enforcement and tagging handled by CheckSBRRBS; not applied here
   if(IsBullish(sigType))
      return (fibPos >= 0.0 && fibPos <= InpFibBuyZoneMax);
   else
      return (fibPos >= InpFibSellZoneMin && fibPos <= 1.0);
}

//+------------------------------------------------------------------+
//  CheckSBRRBS – direction-enforced role-flip zone check
//  SBR: SELL only – price testing old swing low (broken support → resistance)
//       zone: [old_swing_low - DeepExt*range, old_swing_low + Tol*range]
//  RBS: BUY  only – price testing old swing high (broken resistance → support)
//       zone: [old_swing_high - Tol*range, old_swing_high + DeepExt*range]
//+------------------------------------------------------------------+
bool CheckSBRRBS(int stochState, double &fibPos, string &roleTag, double &levelPrice)
{
   fibPos = -1.0; roleTag = ""; levelPrice = 0.0;

   double range = g_fibSwingHigh - g_fibSwingLow;
   if(range <= 0.0) return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(IsBearish(stochState) && g_hasOldLow)
   {
      // SBR SELL: price came back up to test old swing low (now resistance)
      double zoneLo = g_oldSwingLow - InpSBR_DeepExt * range;
      double zoneHi = g_oldSwingLow + InpSBR_Tol     * range;
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
      // RBS BUY: price came back down to test old swing high (now support)
      double zoneLo = g_oldSwingHigh - InpSBR_Tol     * range;
      double zoneHi = g_oldSwingHigh + InpRBS_DeepExt * range;
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
//  HasRejectionCandle – scan TF1 bars for textbook rejection pattern
//  bearish=true  → SBR SELL: shooting star, bearish engulf, outside bar, doji
//  bearish=false → RBS BUY:  hammer, bullish engulf, outside bar, doji
//  Candle high must reach SBR zone (bearish) / low must reach RBS zone (bullish).
//  No qualifying candle found = manipulation / liquidity grab → signal skipped.
//+------------------------------------------------------------------+
bool HasRejectionCandle(bool bearish, double levelPrice, ENUM_TIMEFRAMES tf, int lookback)
{
   double opens[], highs[], lows[], closes[];
   if(CopyOpen (_Symbol, tf, 1, lookback, opens)  < lookback) return false;
   if(CopyHigh (_Symbol, tf, 1, lookback, highs)  < lookback) return false;
   if(CopyLow  (_Symbol, tf, 1, lookback, lows)   < lookback) return false;
   if(CopyClose(_Symbol, tf, 1, lookback, closes) < lookback) return false;
   // [0] = most recent closed bar (shift 1); [lookback-1] = oldest

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
         // Candle high must reach into or above the SBR zone
         if(h < levelPrice - priceTol) continue;

         double upperWick = h - MathMax(o, c);

         // Shooting star / bearish pin bar: upper wick >= 2× body, closes in lower half
         bool shootingStar = (body > 0)
                          && (upperWick >= 2.0 * body)
                          && (c < (h + l) * 0.5);

         // Doji: body <= 10% of candle range — ambiguous candle at resistance = rejection hint
         bool doji = (body <= 0.10 * cRange);

         bool outsideBar = false, engulfing = false;
         if(i + 1 < lookback)
         {
            double ph = highs[i+1], pl = lows[i+1];
            double pO = opens[i+1], pC = closes[i+1];
            // Outside bar: breaks both prev extremes, closes bearish
            outsideBar = (h > ph) && (l < pl) && (c < o);
            // Bearish engulfing: opens at/above prev body top, closes at/below prev body bottom
            engulfing  = (c < o)
                      && (o >= MathMax(pO, pC))
                      && (c <= MathMin(pO, pC));
         }

         if(shootingStar || doji || outsideBar || engulfing)
         {
            string ptype = shootingStar ? "ShootingStar" :
                           doji         ? "Doji"         :
                           outsideBar   ? "OutsideBar"   : "BearEngulf";
            Print("[REJECT-SBR] ", ptype,
                  " H=", DoubleToString(h, _Digits),
                  " level=", DoubleToString(levelPrice, _Digits),
                  " bar=", i+1, " ago");
            return true;
         }
      }
      else
      {
         // Candle low must reach into or below the RBS zone
         if(l > levelPrice + priceTol) continue;

         double lowerWick = MathMin(o, c) - l;

         // Hammer / bullish pin bar: lower wick >= 2× body, closes in upper half
         bool hammer = (body > 0)
                    && (lowerWick >= 2.0 * body)
                    && (c > (h + l) * 0.5);

         bool doji = (body <= 0.10 * cRange);

         bool outsideBar = false, engulfing = false;
         if(i + 1 < lookback)
         {
            double ph = highs[i+1], pl = lows[i+1];
            double pO = opens[i+1], pC = closes[i+1];
            // Outside bar: breaks both prev extremes, closes bullish
            outsideBar = (h > ph) && (l < pl) && (c > o);
            // Bullish engulfing: opens at/below prev body bottom, closes at/above prev body top
            engulfing  = (c > o)
                      && (o <= MathMin(pO, pC))
                      && (c >= MathMax(pO, pC));
         }

         if(hammer || doji || outsideBar || engulfing)
         {
            string ptype = hammer     ? "Hammer"     :
                           doji       ? "Doji"       :
                           outsideBar ? "OutsideBar" : "BullEngulf";
            Print("[REJECT-RBS] ", ptype,
                  " L=", DoubleToString(l, _Digits),
                  " level=", DoubleToString(levelPrice, _Digits),
                  " bar=", i+1, " ago");
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
//  🟢 BUY RISKY XAUUSD.p @ FIB 0.236
//  🟢 BUY RISKY (SBR) XAUUSD.p @ FIB 0.236
//+------------------------------------------------------------------+
void FireArmedAlert(int sigType, double fibPos, string fibTag)
{
   string emoji = IsBullish(sigType) ? "🟢" : "🔴";
   string tag   = fibTag == "" ? "" : " (" + fibTag + ")";
   string msg   = emoji + " " + SignalTypeName(sigType) + " RISKY" + tag
                + " " + _Symbol
                + " @ FIB " + FibPosLabel(fibPos);

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
                      bool strictZones, double &crossK)
{
   crossK = 0.0;

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

   crossK = k1;  // capture K value at the cross bar

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

   // Use the fib context stored at RISKY time – price moving after the cross is
   // the trade working, not a reason to block SAFE
   double fibPos = bullish ? g_riskyBuyFibPos  : g_riskySellFibPos;
   string fibTag = bullish ? g_riskyBuyTag     : g_riskySellTag;
   double kEntry = bullish ? g_riskyBuyK       : g_riskySellK;

   Print("[SAFE CONTEXT] entry fib=", FibPosLabel(fibPos),
         " K_at_entry=", DoubleToString(kEntry, 1),
         " TF1 K_now=",  DoubleToString(g_liveK_1, 1),
         " TF2 K_now=",  DoubleToString(g_liveK_2, 1));

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
