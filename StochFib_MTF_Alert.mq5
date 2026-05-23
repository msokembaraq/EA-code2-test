//+------------------------------------------------------------------+
//|                   StochFib_MTF_Alert.mq5                         |
//|  Dual-TF Stochastic – Pure Signal                               |
//|  v5.0                                                            |
//|                                                                  |
//|  BUY:        OS touch (0-10) → recover >15 → cross up 15-30     |
//|  BUY AGAIN:  Retrace to 10-30 → cross up                       |
//|  BUY MOM:    K ≤ 10, K > D (turning up from OS)                |
//|                                                                  |
//|  SELL:       OB touch (90-100) → reject <90 → cross down 80-90 |
//|  SELL AGAIN: Pullback to 80-90 → cross down                    |
//|  SELL MOM:   K ≥ 90, K < D (turning down from OB)              |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "5.00"
#property description "Dual-TF Stoch: Recovery + Momentum signals"
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
input ENUM_TIMEFRAMES InpTF1      = PERIOD_M5;
input bool            InpEnableTF2 = true;
input ENUM_TIMEFRAMES InpTF2      = PERIOD_M15;

input group "══════ Stochastic – TF1 ══════"
input int    InpStoch_K    = 26;
input int    InpStoch_D    = 7;
input int    InpStoch_Slow = 11;

input group "══════ Stochastic – TF2 ══════"
input int    InpStoch_K2    = 14;
input int    InpStoch_D2    = 3;
input int    InpStoch_Slow2 = 9;

input group "══════ OB / OS Extremes ══════"
input double InpOB_Level   = 90.0;   // OB zone entry
input double InpOS_Level   = 10.0;   // OS zone entry
input double InpOS_Recover = 15.0;   // BUY: K must recover above this after OS touch
input double InpOB_Reject  = 90.0;   // SELL: K must drop below this after OB touch

input group "══════ Recovery / Continuation Zones ══════"
input double InpBuyZoneHi  = 30.0;   // BUY AGAIN zone upper
input double InpBuyZoneLo  = 10.0;   // BUY AGAIN zone lower
input double InpSellZoneHi = 90.0;   // SELL AGAIN zone upper
input double InpSellZoneLo = 80.0;   // SELL AGAIN zone lower

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

datetime g_lastBar_1       = 0;
datetime g_lastMomentumBar = 0;   // prevent momentum spam on same bar

int      g_lastCooldownSig  = SIG_NONE;
datetime g_lastCooldownTime = 0;

double g_liveK_1 = 0.0, g_liveK_2 = 0.0;

bool g_touchedOS = false;
bool g_touchedOB = false;

bool g_alertedOB = false;   // fired once when K enters OB zone
bool g_alertedOS = false;   // fired once when K enters OS zone

//+------------------------------------------------------------------+
//  OnInit
//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBar_1       = 0;
   g_lastMomentumBar = 0;
   g_lastCooldownSig  = SIG_NONE;
   g_lastCooldownTime = 0;
   g_liveK_1 = g_liveK_2 = 0.0;
   g_touchedOS = false;
   g_touchedOB = false;
   g_alertedOB = false;
   g_alertedOS = false;

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

   Print("StochFib v5.0 loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1),
         " | OB:", InpOB_Level, " OS:", InpOS_Level,
         " | Recovery:", InpOS_Recover, "/", InpOB_Reject,
         InpEnableTF2 ? " | TF2:" + TFName(InpTF2) : " | TF2: DISABLED");

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
//  UpdateLiveK
//+------------------------------------------------------------------+
void UpdateLiveK()
{
   double k[1];
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE, 0, 1, k) == 1)
   {
      g_liveK_1 = k[0];

      if(g_liveK_1 <= InpOS_Level) g_touchedOS = true;
      if(g_liveK_1 >= InpOB_Level) g_touchedOB = true;

      // Reset memory when cycle completes
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
   if(g_touchedOS) mem += " [OS]";
   if(g_touchedOB) mem += " [OB]";

   string tf2info = "";
   if(InpEnableTF2)
   {
      int    tf2Str  = 0;
      int    tf2Bias = GetTF2LiveBias(tf2Str);
      string tf2st   = (tf2Bias == SIG_BUY ? "BUY" : tf2Bias == SIG_SELL ? "SELL" : "none");
      if(tf2Bias != SIG_NONE) tf2st += (tf2Str == 1 ? "-OBOS" : "-MID");
      tf2info = " | " + TFName(InpTF2) + " K=" + DoubleToString(g_liveK_2, 1) + " " + tf2st;
   }

   Print("[WATCH] ", TFName(InpTF1), " K=", DoubleToString(g_liveK_1, 1), mem, tf2info);
}

//+------------------------------------------------------------------+
//  CheckZoneEntry – alert once on OB/OS entry, reset on exit
//+------------------------------------------------------------------+
void CheckZoneEntry()
{
   // OB entry
   if(g_liveK_1 >= InpOB_Level)
   {
      if(!g_alertedOB)
      {
         string msg = "⚠️ OB ZONE  " + _Symbol + "  " + TFName(InpTF1)
                    + "  K=" + DoubleToString(g_liveK_1, 1);
         if(InpEnablePrint) Print(msg);
         if(InpEnablePush)  SendNotification(msg);
         g_alertedOB = true;
      }
   }
   else
      g_alertedOB = false;

   // OS entry
   if(g_liveK_1 <= InpOS_Level)
   {
      if(!g_alertedOS)
      {
         string msg = "⚠️ OS ZONE  " + _Symbol + "  " + TFName(InpTF1)
                    + "  K=" + DoubleToString(g_liveK_1, 1);
         if(InpEnablePrint) Print(msg);
         if(InpEnablePush)  SendNotification(msg);
         g_alertedOS = true;
      }
   }
   else
      g_alertedOS = false;
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   UpdateLiveK();
   CheckZoneEntry();
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
      sl = (CopyLow(_Symbol, InpTF1, 1, InpSLLookback, arr) == InpSLLookback)
           ? arr[ArrayMinimum(arr)] : entry - InpSLFallback * _Point;
      risk = entry - sl;
      if(risk <= 0) { risk = InpSLFallback * _Point; }
      tp1 = entry + risk * InpTP1_RR;
      tp2 = entry + risk * InpTP2_RR;
      tp3 = entry + risk * InpTP3_RR;
   }
   else
   {
      sl = (CopyHigh(_Symbol, InpTF1, 1, InpSLLookback, arr) == InpSLLookback)
           ? arr[ArrayMaximum(arr)] : entry + InpSLFallback * _Point;
      risk = sl - entry;
      if(risk <= 0) { risk = InpSLFallback * _Point; }
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
   double entry = (sigType == SIG_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp1, tp2, tp3;
   CalcTPSL(sigType, entry, sl, tp1, tp2, tp3);

   string emoji = (sigType == SIG_BUY) ? "🟢" : "🔴";

   string msg = emoji + " " + label + " " + _Symbol
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
//  BUY:        OS touch (0-10) → recover >15 → cross up in 15-30
//  BUY AGAIN:  Retrace to 10-30 → cross up
//  BUY MOM:    K ≤ 10, K > D – turning up from OS (each bar)
//
//  SELL:       OB touch (90-100) → reject <90 → cross down in 80-90
//  SELL AGAIN: Pullback to 80-90 → cross down
//  SELL MOM:   K ≥ 90, K < D – turning down from OB (each bar)
//+------------------------------------------------------------------+
void CheckTF1Signal()
{
   datetime barTimes[3];
   if(CopyTime(_Symbol, InpTF1, 0, 3, barTimes) < 3) return;

   // ── TF1 K/D data ──
   double k_buf[3], d_buf[3];
   if(CopyBuffer(g_h_stoch_1, MAIN_LINE,   0, 3, k_buf) < 3) return;
   if(CopyBuffer(g_h_stoch_1, SIGNAL_LINE, 0, 3, d_buf) < 3) return;

   double k_now  = k_buf[1], d_now  = d_buf[1];
   double k_prev = k_buf[2], d_prev = d_buf[2];

   bool crossUp   = (k_prev <= d_prev) && (k_now > d_now);
   bool crossDown = (k_prev >= d_prev) && (k_now < d_now);

   // ── TF2 (if enabled) ──
   int tf2Strength = 0;
   int tf2Bias = SIG_NONE;
   if(InpEnableTF2) tf2Bias = GetTF2LiveBias(tf2Strength);

   int    tf1sig      = SIG_NONE;
   string label       = "";
   string blockReason = "";

   // ════════════════════════════════════════════════
   //  MOMENTUM SIGNALS (no cross needed, each bar)
   // ════════════════════════════════════════════════
   if(k_now <= InpOS_Level && k_now > d_now)
   {
      tf1sig = SIG_BUY;
      label  = "BUY MOM";
   }
   else if(k_now >= InpOB_Level && k_now < d_now)
   {
      tf1sig = SIG_SELL;
      label  = "SELL MOM";
   }

   // ════════════════════════════════════════════════
   //  CROSS-BASED SIGNALS
   // ════════════════════════════════════════════════
   if(tf1sig == SIG_NONE && (crossUp || crossDown))
   {
      tf1sig = crossUp ? SIG_BUY : SIG_SELL;

      // Relaxed zone when TF2 on correct side
      bool relaxed = false;
      if(InpEnableTF2 && tf2Bias != SIG_NONE)
      {
         if(tf1sig == SIG_BUY  && g_liveK_2 <= 50.0) relaxed = true;
         if(tf1sig == SIG_SELL && g_liveK_2 >= 50.0) relaxed = true;
      }

      if(tf1sig == SIG_BUY)
      {
         // BUY: OS touched + recovered above 15 + cross in 15-30
         if(g_touchedOS && k_now > InpOS_Recover && k_now >= InpBuyZoneLo && k_now <= InpBuyZoneHi)
         {
            label = "BUY";
         }
         // BUY AGAIN: cross in 10-30 (no OS touch needed for continuation)
         else if(k_now >= InpBuyZoneLo && k_now <= InpBuyZoneHi)
         {
            label = "BUY AGAIN";
         }
         // Relaxed: any cross up with K <= 50
         else if(relaxed && k_now <= 50.0 && k_now > InpOS_Recover)
         {
            label = "BUY AGAIN";
         }
         else
         {
            if(k_now < InpBuyZoneLo)   blockReason = "K=" + DoubleToString(k_now,1) + " too low (<" + DoubleToString(InpBuyZoneLo,0) + ")";
            else if(k_now > InpBuyZoneHi && !relaxed) blockReason = "K=" + DoubleToString(k_now,1) + " too high (>" + DoubleToString(InpBuyZoneHi,0) + ") no OS recovery";
            else if(!g_touchedOS && k_now <= InpOS_Recover) blockReason = "OS not touched, K still <= " + DoubleToString(InpOS_Recover,0);
            else blockReason = "no BUY zone match";
         }
      }
      else // SELL
      {
         // SELL: OB touched + rejected below 90 + cross down in 80-90
         if(g_touchedOB && k_now < InpOB_Reject && k_now >= InpSellZoneLo && k_now <= InpSellZoneHi)
         {
            label = "SELL";
         }
         // SELL AGAIN: cross down in 80-90 (no OB touch needed for continuation)
         else if(k_now >= InpSellZoneLo && k_now <= InpSellZoneHi)
         {
            label = "SELL AGAIN";
         }
         // Relaxed: any cross down with K >= 50
         else if(relaxed && k_now >= 50.0 && k_now < InpOB_Reject)
         {
            label = "SELL AGAIN";
         }
         else
         {
            if(k_now > InpSellZoneHi)    blockReason = "K=" + DoubleToString(k_now,1) + " too high (>" + DoubleToString(InpSellZoneHi,0) + ")";
            else if(k_now < InpSellZoneLo && !relaxed) blockReason = "K=" + DoubleToString(k_now,1) + " too low (<" + DoubleToString(InpSellZoneLo,0) + ") no OB rejection";
            else if(!g_touchedOB && k_now >= InpOB_Reject) blockReason = "OB not touched, K still >= " + DoubleToString(InpOB_Reject,0);
            else blockReason = "no SELL zone match";
         }
      }
   }

   // ════════════════════════════════════════════════
   //  NO VALID SIGNAL
   // ════════════════════════════════════════════════
   if(tf1sig == SIG_NONE || label == "")
   {
      if(InpEnablePrint && (crossUp || crossDown) && blockReason != "")
         Print("[BLOCKED] ", crossUp ? "BUY" : "SELL", " cross K=", DoubleToString(k_now,1), " – ", blockReason);
      return;
   }

   // ════════════════════════════════════════════════
   //  MOMENTUM: only fire once per bar
   // ════════════════════════════════════════════════
   bool isMomentum = (StringFind(label, "MOM") >= 0);
   if(isMomentum)
   {
      if(barTimes[1] == g_lastMomentumBar) return;
   }

   // ════════════════════════════════════════════════
   //  BAR GUARD (non-momentum)
   // ════════════════════════════════════════════════
   if(!isMomentum && barTimes[1] == g_lastBar_1) return;

   SilentWatch();

   // ════════════════════════════════════════════════
   //  DUAL-TF AGREEMENT
   // ════════════════════════════════════════════════
   if(InpEnableTF2)
   {
      if(tf2Bias == SIG_NONE)
      {
         if(InpEnablePrint) Print("[WAIT] TF2 flat – TF1=", SignalTypeName(tf1sig));
         return;
      }
      if(tf1sig != tf2Bias)
      {
         if(InpEnablePrint) Print("[WAIT] TF1=", SignalTypeName(tf1sig), " TF2=", SignalTypeName(tf2Bias), " – no agreement");
         return;
      }
      // Append AGAIN if TF2 mid-zone and not already AGAIN/MOM
      if(tf2Strength == 0 && StringFind(label, "AGAIN") < 0 && StringFind(label, "MOM") < 0)
         label = label + " AGAIN";
   }

   // ════════════════════════════════════════════════
   //  COOLDOWN (skip for momentum)
   // ════════════════════════════════════════════════
   if(!isMomentum && !PassesCooldown(tf1sig, barTimes[1]))
   {
      if(InpEnablePrint) Print("[COOLDOWN] ", SignalTypeName(tf1sig), " blocked");
      return;
   }

   // ════════════════════════════════════════════════
   //  FIRE
   // ════════════════════════════════════════════════
   Print("[", label, "] ", SignalTypeName(tf1sig),
         "  TF1 K=", DoubleToString(k_now,1), " D=", DoubleToString(d_now,1),
         "  OS:", g_touchedOS ? "Y" : "N", " OB:", g_touchedOB ? "Y" : "N",
         InpEnableTF2 ? "  TF2 K=" + DoubleToString(g_liveK_2,1) + " " + (tf2Strength==1?"STRONG":"SECONDARY") : "");

   FireSignal(tf1sig, label);

   // Update guards
   if(isMomentum)
      g_lastMomentumBar = barTimes[1];
   else
   {
      g_lastBar_1 = barTimes[1];
      g_lastCooldownSig  = tf1sig;
      g_lastCooldownTime = barTimes[1];
      // Reset touch memory after firing recovery signal
      if(label == "BUY")  g_touchedOS = false;
      if(label == "SELL") g_touchedOB = false;
   }
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
