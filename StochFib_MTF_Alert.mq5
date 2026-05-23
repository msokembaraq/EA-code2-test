//+------------------------------------------------------------------+
//|                   StochFib_MTF_Alert.mq5                         |
//|  Dual-TF Stochastic – Pure Signal                               |
//|  v4.0                                                            |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|                                                                  |
//|  BUY requires:  K touched OS (<=10) then recovered (>10)        |
//|  SELL requires: K touched OB (>=90) then rejected (<90)         |
//|                                                                  |
//|  Single-TF:                                                      |
//|    BUY:       K 10–30 after OS touch → cross up                 |
//|    BUY AGAIN: K 10–30 continuation cross up                     |
//|    SELL:      K 80–95 after OB touch → cross down               |
//|    SELL AGAIN:K 80–95 continuation cross down                   |
//|                                                                  |
//|  Dual-TF:                                                        |
//|    TF2 correct side → relaxed (K past 50)                       |
//|    TF2 wrong side   → strict (same as single-TF)                |
//|    TF2 grades: OB/OS=STRONG | mid-zone=SECONDARY                |
//|    No agreement = NO SIGNAL                                     |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "4.00"
#property description "Dual-TF Stoch: OS/OB touch required before signal"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  CONSTANTS
//════════════════════════════════════════════════════════════════════
#define SIG_NONE  0
#define SIG_BUY   1
#define SIG_SELL  2

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1      = PERIOD_M5;   // TF1 – trigger
input bool            InpEnableTF2 = true;        // Enable TF2 for dual-TF confirmation
input ENUM_TIMEFRAMES InpTF2      = PERIOD_M15;  // TF2 – direction

input group "══════ Stochastic – TF1 ══════"
input int    InpStoch_K    = 26;
input int    InpStoch_D    = 7;
input int    InpStoch_Slow = 11;

input group "══════ Stochastic – TF2 ══════"
input int    InpStoch_K2    = 14;
input int    InpStoch_D2    = 3;
input int    InpStoch_Slow2 = 9;

input group "══════ OB / OS Extremes ══════"
input double InpOB_Level    = 90.0;  // K must touch this to enable SELL
input double InpOS_Level    = 10.0;  // K must touch this to enable BUY
input double InpOB_Reject   = 90.0;  // K must drop below this after OB touch for SELL
input double InpOS_Recover  = 10.0;  // K must rise above this after OS touch for BUY

input group "══════ Cross Zones ══════"
input double InpSellZoneHi  = 95.0;  // SELL AGAIN zone upper bound
input double InpSellZoneLo  = 80.0;  // SELL AGAIN zone lower bound
input double InpBuyZoneHi   = 30.0;  // BUY AGAIN zone upper bound
input double InpBuyZoneLo   = 10.0;  // BUY AGAIN zone lower bound

input group "══════ Signal Cooldown ══════"
input int    InpSignalCooldownMin = 60;

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

datetime g_lastBar_1 = 0;

int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;

double g_liveK_1 = 0.0, g_liveK_2 = 0.0;

// OS/OB touch memory for TF1
bool   g_touchedOS = false;   // K has been <= InpOS_Level recently
bool   g_touchedOB = false;   // K has been >= InpOB_Level recently

//+------------------------------------------------------------------+
//  OnInit
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1 = 0;
   g_lastCooldownSig  = SIG_NONE;
   g_lastCooldownTime = 0;
   g_liveK_1 = g_liveK_2 = 0.0;
   g_touchedOS = false;
   g_touchedOB = false;

   g_h_stoch_1 = iStochastic(_Symbol, InpTF1,
                              InpStoch_K, InpStoch_D, InpStoch_Slow,
                              MODE_SMA, STO_LOWHIGH);
   if(g_h_stoch_1 == INVALID_HANDLE)
   { Alert("StochFib: Failed Stoch TF1 handle"); return INIT_FAILED; }

   if(InpEnableTF2)
   {
      g_h_stoch_2 = iStochastic(_Symbol, InpTF2,
                                 InpStoch_K2, InpStoch_D2, InpStoch_Slow2,
                                 MODE_SMA, STO_LOWHIGH);
      if(g_h_stoch_2 == INVALID_HANDLE)
      { Alert("StochFib: Failed Stoch TF2 handle"); return INIT_FAILED; }
   }

   EventSetTimer(2);

   Print("StochFib v4.0 loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1), " Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | OB:", InpOB_Level, " OS:", InpOS_Level,
         InpEnableTF2 ? " | TF2:" + TFName(InpTF2) + " Stoch(" + IntegerToString(InpStoch_K2) + "," + IntegerToString(InpStoch_D2) + "," + IntegerToString(InpStoch_Slow2) + ")" : " | TF2: DISABLED");

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
//  UpdateLiveK – tracks live K and OS/OB touch memory
//+------------------------------------------------------------------+
void UpdateLiveK()
{
   double k[1];
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE, 0, 1, k) == 1)
   {
      g_liveK_1 = k[0];

      // Update OS/OB touch memory
      if(g_liveK_1 <= InpOS_Level) g_touchedOS = true;
      if(g_liveK_1 >= InpOB_Level) g_touchedOB = true;

      // Reset memory when price recovers past midpoint (cycle complete)
      if(g_liveK_1 > 50.0) g_touchedOS = false;
      if(g_liveK_1 < 50.0) g_touchedOB = false;
   }

   if(InpEnableTF2 && g_h_stoch_2 != INVALID_HANDLE)
      if(CopyBuffer(g_h_stoch_2, MAIN_LINE, 0, 1, k) == 1) g_liveK_2 = k[0];
}

//+------------------------------------------------------------------+
//  GetTF2LiveBias
//+------------------------------------------------------------------+
int GetTF2LiveBias(int &outStrength)
{
   outStrength = 0;
   if(!InpEnableTF2 || g_h_stoch_2 == INVALID_HANDLE) return SIG_NONE;

   double k[1], d[1];
   if(CopyBuffer(g_h_stoch_2, MAIN_LINE,   1, 1, k) < 1) return SIG_NONE;
   if(CopyBuffer(g_h_stoch_2, SIGNAL_LINE, 1, 1, d) < 1) return SIG_NONE;

   int bias = SIG_NONE;
   if(k[0] < d[0]) bias = SIG_SELL;
   if(k[0] > d[0]) bias = SIG_BUY;
   if(bias == SIG_NONE) return SIG_NONE;

   // TF2 OB/OS strength
   if(bias == SIG_SELL && k[0] >= InpOB_Level) outStrength = 1;
   if(bias == SIG_BUY  && k[0] <= InpOS_Level) outStrength = 1;

   return bias;
}

//+------------------------------------------------------------------+
//  SilentWatch
//+------------------------------------------------------------------+
void SilentWatch()
{
   if(!InpEnablePrint) return;

   string mem = "";
   if(g_touchedOS) mem += " [OS touched]";
   if(g_touchedOB) mem += " [OB touched]";

   string tf2info = "";
   if(InpEnableTF2)
   {
      int    tf2Str  = 0;
      int    tf2Bias = GetTF2LiveBias(tf2Str);
      string tf2st   = (tf2Bias == SIG_BUY ? "BUY" : tf2Bias == SIG_SELL ? "SELL" : "none");
      if(tf2Bias != SIG_NONE) tf2st += (tf2Str == 1 ? "-OBOS" : "-MID");
      tf2info = " | " + TFName(InpTF2) + " K=" + DoubleToString(g_liveK_2, 1) + " bias=" + tf2st;
   }

   Print("[WATCH] ",
         TFName(InpTF1), " K=", DoubleToString(g_liveK_1, 1), mem, tf2info);
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   UpdateLiveK();
   CheckTF1Signal();
}

//════════════════════════════════════════════════════════════════════
//  HELPERS
//════════════════════════════════════════════════════════════════════

string TFName(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

string SignalTypeName(int sig) { return sig == SIG_BUY ? "BUY" : "SELL"; }

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
//  CalcTPSL
//+------------------------------------------------------------------+
void CalcTPSL(int sigType, double entry,
              double &sl, double &tp1, double &tp2, double &tp3)
{
   double arr[];
   double risk;

   if(sigType == SIG_BUY)
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
//  FireSignal
//+------------------------------------------------------------------+
void FireSignal(int sigType, string label)
{
   double entry = (sigType == SIG_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp1, tp2, tp3;
   CalcTPSL(sigType, entry, sl, tp1, tp2, tp3);

   string emoji = (sigType == SIG_BUY) ? "🟢" : "🔴";

   string msg = emoji + " " + label
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
//  CheckTF1Signal
//
//  BUY  requires: K touched OS (<=10), recovered (>10), cross up
//  SELL requires: K touched OB (>=90), rejected (<90), cross down
//
//  Single-TF:
//    BUY:       K 10–30 after OS touch
//    BUY AGAIN: K 10–30 continuation
//    SELL:      K 80–95 after OB touch
//    SELL AGAIN:K 80–95 continuation
//
//  Dual-TF:
//    TF2 correct side → relaxed (K past 50)
//    TF2 wrong side   → strict (same as single-TF)
//    No agreement = NO SIGNAL
//+------------------------------------------------------------------+
void CheckTF1Signal()
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, InpTF1, 0, 3, barTimes) < 3) return;
   if(barTimes[1] == g_lastBar_1) return;
   g_lastBar_1 = barTimes[1];

   SilentWatch();

   // ── TF1 K/D cross ──
   double k_buf[3], d_buf[3];
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE,   0, 3, k_buf) < 3) return;
   if(CopyBuffer(g_h_stoch_1, SIGNAL_LINE, 0, 3, d_buf) < 3) return;

   double k_now  = k_buf[1], d_now  = d_buf[1];
   double k_prev = k_buf[2], d_prev = d_buf[2];

   bool crossUp   = (k_prev <= d_prev) && (k_now > d_now);
   bool crossDown = (k_prev >= d_prev) && (k_now < d_now);
   if(!crossUp && !crossDown) return;

   int tf1sig = crossUp ? SIG_BUY : SIG_SELL;

   // ── TF2 direction + strength (if enabled) ──
   int tf2Strength = 0;
   int tf2Bias = SIG_NONE;
   if(InpEnableTF2)
      tf2Bias = GetTF2LiveBias(tf2Strength);

   // ════════════════════════════════════════════════
   //  TF1 ZONE FILTER + OS/OB TOUCH REQUIREMENT
   // ════════════════════════════════════════════════

   bool useRelaxedZone = false;
   if(InpEnableTF2 && tf2Bias != SIG_NONE)
   {
      bool tf2OnCorrectSide = false;
      if(tf1sig == SIG_SELL && g_liveK_2 >= 50.0) tf2OnCorrectSide = true;
      if(tf1sig == SIG_BUY  && g_liveK_2 <= 50.0) tf2OnCorrectSide = true;
      if(tf2OnCorrectSide) useRelaxedZone = true;
   }

   bool   tf1Passed = false;
   string label     = "";
   string blockReason = "";

   if(useRelaxedZone)
   {
      // Relaxed: TF1 K past midpoint + touch requirement still applies
      if(tf1sig == SIG_SELL && k_now >= 50.0)
      {
         if(g_touchedOB && k_now < InpOB_Reject) { tf1Passed = true; label = "SELL"; }
         else if(!g_touchedOB) blockReason = "OB not touched yet";
         else blockReason = "K still above rejection level";
      }
      if(tf1sig == SIG_BUY && k_now <= 50.0)
      {
         if(g_touchedOS && k_now > InpOS_Recover) { tf1Passed = true; label = "BUY"; }
         else if(!g_touchedOS) blockReason = "OS not touched yet";
         else blockReason = "K still below recovery level";
      }
   }
   else
   {
      // Strict zone rules with OS/OB touch requirement
      if(tf1sig == SIG_SELL)
      {
         if(!g_touchedOB)
         {
            blockReason = "OB not touched yet (K never >= " + DoubleToString(InpOB_Level, 0) + ")";
         }
         else if(k_now >= InpOB_Reject)
         {
            blockReason = "K still >= " + DoubleToString(InpOB_Reject, 0) + " (no rejection yet)";
         }
         else if(k_now >= InpSellZoneLo && k_now <= InpSellZoneHi)
         {
            tf1Passed = true;
            label = "SELL AGAIN";
         }
         else if(k_now >= InpOB_Level)
         {
            // Shouldn't reach here due to rejection check, but safety
            blockReason = "K in OB, wait for rejection below " + DoubleToString(InpOB_Reject, 0);
         }
         else
         {
            blockReason = "K=" + DoubleToString(k_now, 1) + " outside SELL zones";
         }
      }
      if(tf1sig == SIG_BUY)
      {
         if(!g_touchedOS)
         {
            blockReason = "OS not touched yet (K never <= " + DoubleToString(InpOS_Level, 0) + ")";
         }
         else if(k_now <= InpOS_Recover)
         {
            blockReason = "K still <= " + DoubleToString(InpOS_Recover, 0) + " (no recovery yet)";
         }
         else if(k_now >= InpBuyZoneLo && k_now <= InpBuyZoneHi)
         {
            tf1Passed = true;
            label = "BUY AGAIN";
         }
         else if(k_now <= InpOS_Level)
         {
            blockReason = "K in OS, wait for recovery above " + DoubleToString(InpOS_Recover, 0);
         }
         else
         {
            blockReason = "K=" + DoubleToString(k_now, 1) + " outside BUY zones";
         }
      }
   }

   if(!tf1Passed)
   {
      if(InpEnablePrint)
         Print("[TF1 BLOCKED] ", SignalTypeName(tf1sig), " cross K=", DoubleToString(k_now, 1),
               " – ", blockReason);
      return;
   }

   // ════════════════════════════════════════════════
   //  DUAL-TF: MUST HAVE AGREEMENT
   // ════════════════════════════════════════════════
   if(InpEnableTF2)
   {
      if(tf2Bias == SIG_NONE)
      {
         if(InpEnablePrint)
            Print("[WAIT] TF2 K/D flat – TF1=", SignalTypeName(tf1sig));
         return;
      }

      if(tf1sig != tf2Bias)
      {
         if(InpEnablePrint)
            Print("[WAIT] TF1=", SignalTypeName(tf1sig),
                  " TF2=", SignalTypeName(tf2Bias), " – no agreement");
         return;
      }

      // Grade by TF2 zone strength
      bool isStrong = (tf2Strength == 1);
      if(!isStrong && StringFind(label, "AGAIN") < 0)
         label = label + " AGAIN";
   }

   // ════════════════════════════════════════════════
   //  SIGNAL CONFIRMED
   // ════════════════════════════════════════════════
   if(!PassesCooldown(tf1sig, barTimes[1]))
   {
      if(InpEnablePrint)
         Print("[COOLDOWN] ", SignalTypeName(tf1sig), " blocked");
      return;
   }

   Print("[", label, "] ", SignalTypeName(tf1sig),
         "  TF1 K=", DoubleToString(k_now, 1),
         "  touchedOS=", g_touchedOS ? "Y" : "N",
         "  touchedOB=", g_touchedOB ? "Y" : "N",
         InpEnableTF2 ? "  TF2 K=" + DoubleToString(g_liveK_2, 1) : "",
         InpEnableTF2 ? "  TF2=" + string(tf2Strength == 1 ? "STRONG" : "SECONDARY") : "  (single-TF)");

   FireSignal(tf1sig, label);
   g_lastCooldownSig  = tf1sig;
   g_lastCooldownTime = barTimes[1];

   // Reset touch memory after firing
   if(tf1sig == SIG_BUY)  g_touchedOS = false;
   if(tf1sig == SIG_SELL) g_touchedOB = false;
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
