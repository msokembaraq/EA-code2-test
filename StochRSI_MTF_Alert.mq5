//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with RSI(1) Level Filter + Pivots        |
//|    Multi-Timeframe – selectable TF1 / TF2, both must agree       |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   BUY        – K crosses D UP   while RSI in OS zone  (1–8)      |
//|   SELL       – K crosses D DOWN while RSI in OB zone  (90–98)    |
//|   BUY AGAIN  – K crosses D UP   while RSI in 15–40              |
//|                AND cross K level > last BUY pivot  (higher high) |
//|   SELL AGAIN – K crosses D DOWN while RSI in 60–80              |
//|                AND cross K level < last SELL pivot (lower low)   |
//|                                                                  |
//|  CONFIRMATION: alert fires only when TF1 AND TF2 detect the same |
//|  signal type within InpConfirmMins of each other.                |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "1.30"
#property description "Stoch K/D cross filtered by RSI(1) level – dual-TF confirmed alerts"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ RSI Settings ══════"
input int    InpRSI_Period     = 1;      // RSI Period
input double InpRSI_OB_High   = 98.0;   // OB Upper Bound
input double InpRSI_OB_Low    = 90.0;   // OB Lower Bound
input double InpRSI_OS_High   = 8.0;    // OS Upper Bound
input double InpRSI_OS_Low    = 1.0;    // OS Lower Bound

input group "══════ Stochastic Settings ══════"
input int    InpStoch_K       = 50;     // %K Period
input int    InpStoch_D       = 7;      // %D Period (signal)
input int    InpStoch_Slow    = 11;     // Slowing

input group "══════ Re-Entry Zone Filters ══════"
input double InpSellAgain_High = 80.0;  // Sell-Again RSI upper
input double InpSellAgain_Low  = 60.0;  // Sell-Again RSI lower
input double InpBuyAgain_High  = 40.0;  // Buy-Again RSI upper
input double InpBuyAgain_Low   = 15.0;  // Buy-Again RSI lower

input group "══════ Timeframe Selection ══════"
input ENUM_TIMEFRAMES InpTF1        = PERIOD_M4;  // Timeframe 1
input bool            InpEnableTF1  = true;        // Enable TF1
input ENUM_TIMEFRAMES InpTF2        = PERIOD_M6;  // Timeframe 2
input bool            InpEnableTF2  = true;        // Enable TF2

input group "══════ Notification Settings ══════"
input int  InpConfirmMins  = 12;    // Confirmation window (minutes) – max gap between TF1 and TF2 signal bars
input bool InpEnablePush   = true;  // Send Push Notification
input bool InpEnablePopup  = false; // Show Alert Popup
input bool InpEnablePrint  = true;  // Print to Journal

input group "══════ Display Settings ══════"
input bool InpDrawArrows    = true;  // Draw signal arrows on chart
input bool InpShowDashboard = true;  // Show info dashboard

//════════════════════════════════════════════════════════════════════
//  SIGNAL TYPE CONSTANTS
//════════════════════════════════════════════════════════════════════
#define SIG_NONE       0
#define SIG_BUY        1
#define SIG_SELL       2
#define SIG_BUY_AGAIN  3
#define SIG_SELL_AGAIN 4

//════════════════════════════════════════════════════════════════════
//  PENDING SIGNAL  –  one per TF, waits for the other TF to agree
//════════════════════════════════════════════════════════════════════
struct PendingSignal
{
   int      type;    // SIG_* constant
   datetime bar;     // closed bar time that generated the signal
   color    clr;     // arrow / display colour
   int      arrow;   // OBJ_ARROW_BUY or OBJ_ARROW_SELL

   void Clear() { type = SIG_NONE; bar = 0; clr = clrNONE; arrow = 0; }
};

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════

// Indicator handles (TF1 / TF2)
int g_h_rsi_1   = INVALID_HANDLE;
int g_h_stoch_1 = INVALID_HANDLE;
int g_h_rsi_2   = INVALID_HANDLE;
int g_h_stoch_2 = INVALID_HANDLE;

// Last processed bar timestamps
datetime g_lastBar_1 = 0;
datetime g_lastBar_2 = 0;

// Pivot memory – K value at last primary signal (per TF)
double g_lastOB_pivot_1 = -1.0;
double g_lastOS_pivot_1 = -1.0;
double g_lastOB_pivot_2 = -1.0;
double g_lastOS_pivot_2 = -1.0;

// Last signal text for dashboard (per TF)
string g_last_signal_1 = "–";
string g_last_signal_2 = "–";

// Arrow counter
int g_arrowCount = 0;

// Pending signals – each TF stores its latest detection here;
// a confirmed alert fires only when both agree on the same type
PendingSignal g_pend_1;
PendingSignal g_pend_2;

//+------------------------------------------------------------------+
//  INIT
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Reset all state (safe across parameter changes)
   g_lastBar_1 = g_lastBar_2 = 0;
   g_lastOB_pivot_1 = g_lastOS_pivot_1 = -1.0;
   g_lastOB_pivot_2 = g_lastOS_pivot_2 = -1.0;
   g_last_signal_1  = g_last_signal_2  = "–";
   g_arrowCount = 0;
   g_pend_1.Clear();
   g_pend_2.Clear();

   //--- Create indicator handles
   g_h_rsi_1   = iRSI       (_Symbol, InpTF1, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_1 = iStochastic(_Symbol, InpTF1, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   g_h_rsi_2   = iRSI       (_Symbol, InpTF2, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_2 = iStochastic(_Symbol, InpTF2, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);

   if(g_h_rsi_1   == INVALID_HANDLE){ Alert("StochRSI: Failed to create RSI TF1 handle");   return INIT_FAILED; }
   if(g_h_stoch_1 == INVALID_HANDLE){ Alert("StochRSI: Failed to create Stoch TF1 handle"); return INIT_FAILED; }
   if(g_h_rsi_2   == INVALID_HANDLE){ Alert("StochRSI: Failed to create RSI TF2 handle");   return INIT_FAILED; }
   if(g_h_stoch_2 == INVALID_HANDLE){ Alert("StochRSI: Failed to create Stoch TF2 handle"); return INIT_FAILED; }

   //--- Recurring 2-second timer to catch bars that form on off-chart TFs
   EventSetTimer(2);

   Print("StochRSI MTF Alert loaded  ", _Symbol,
         " | TF1:", TFName(InpTF1), " TF2:", TFName(InpTF2),
         " | ConfirmWindow:", InpConfirmMins, "min");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//  DEINIT
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(g_h_rsi_1   != INVALID_HANDLE) IndicatorRelease(g_h_rsi_1);
   if(g_h_stoch_1 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_1);
   if(g_h_rsi_2   != INVALID_HANDLE) IndicatorRelease(g_h_rsi_2);
   if(g_h_stoch_2 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_2);

   for(int i = 1; i <= g_arrowCount; i++)
      ObjectDelete(0, StringFormat("StochRSI_Arrow_%d", i));

   Comment("");
}

//+------------------------------------------------------------------+
//  TIMER
//+------------------------------------------------------------------+
void OnTimer() { CheckAllTimeframes(); }

//+------------------------------------------------------------------+
//  MAIN CALCULATION
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   CheckAllTimeframes();
   return rates_total;
}

//+------------------------------------------------------------------+
//  CheckAllTimeframes
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   if(InpEnableTF1)
      ProcessTimeframe(InpTF1,
                       g_h_rsi_1, g_h_stoch_1,
                       g_lastBar_1,
                       g_lastOB_pivot_1, g_lastOS_pivot_1,
                       g_last_signal_1,
                       g_pend_1);

   if(InpEnableTF2)
      ProcessTimeframe(InpTF2,
                       g_h_rsi_2, g_h_stoch_2,
                       g_lastBar_2,
                       g_lastOB_pivot_2, g_lastOS_pivot_2,
                       g_last_signal_2,
                       g_pend_2);

   CheckConfirmation();

   if(InpShowDashboard)
      DrawDashboard();
}

//+------------------------------------------------------------------+
//  ProcessTimeframe – detect signal on one TF and store as pending
//+------------------------------------------------------------------+
void ProcessTimeframe(ENUM_TIMEFRAMES  tf,
                      int              h_rsi,
                      int              h_stoch,
                      datetime        &lastBar,
                      double          &lastOB_pivot,
                      double          &lastOS_pivot,
                      string          &lastSignalTxt,
                      PendingSignal   &pend)
{
   //--- Only act once per newly closed bar
   datetime barTimes[3];
   if(CopyTime(_Symbol, tf, 0, 3, barTimes) < 3) return;
   if(barTimes[1] == lastBar) return;
   lastBar = barTimes[1];

   //--- Read confirmed (closed) bar values
   double rsi_buf[3], k_buf[3], d_buf[3];
   if(CopyBuffer(h_rsi,   0,           0, 3, rsi_buf) < 3) return;
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, 3, k_buf)   < 3) return;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3, d_buf)   < 3) return;

   double rsi = rsi_buf[1];   // last closed bar
   double k1  = k_buf[1];
   double d1  = d_buf[1];
   double k2  = k_buf[2];     // bar before that
   double d2  = d_buf[2];

   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);
   if(!crossedUp && !crossedDown) return;

   //--- ══ PRIMARY BUY ══════════════════════════════════════════════
   if(crossedUp && rsi >= InpRSI_OS_Low && rsi <= InpRSI_OS_High)
   {
      lastOS_pivot  = k1;
      lastSignalTxt = "BUY @ RSI " + DoubleToString(rsi, 1);
      pend.type     = SIG_BUY;
      pend.bar      = barTimes[1];
      pend.clr      = clrLime;
      pend.arrow    = OBJ_ARROW_BUY;
      return;
   }

   //--- ══ PRIMARY SELL ══════════════════════════════════════════════
   if(crossedDown && rsi >= InpRSI_OB_Low && rsi <= InpRSI_OB_High)
   {
      lastOB_pivot  = k1;
      lastSignalTxt = "SELL @ RSI " + DoubleToString(rsi, 1);
      pend.type     = SIG_SELL;
      pend.bar      = barTimes[1];
      pend.clr      = clrRed;
      pend.arrow    = OBJ_ARROW_SELL;
      return;
   }

   //--- ══ SELL AGAIN ════════════════════════════════════════════════
   //    K crosses D downward in the 60–80 RSI zone
   //    Pivot condition: current cross K < previous OB pivot K  (lower low = trend continuation)
   if(crossedDown && rsi >= InpSellAgain_Low && rsi <= InpSellAgain_High)
   {
      if(lastOB_pivot > 0.0 && k1 < lastOB_pivot)
      {
         lastSignalTxt = "SELL AGAIN @ RSI " + DoubleToString(rsi, 1);
         pend.type     = SIG_SELL_AGAIN;
         pend.bar      = barTimes[1];
         pend.clr      = clrOrangeRed;
         pend.arrow    = OBJ_ARROW_SELL;
         lastOB_pivot  = k1;
      }
      return;
   }

   //--- ══ BUY AGAIN ═════════════════════════════════════════════════
   //    K crosses D upward in the 15–40 RSI zone
   //    Pivot condition: current cross K > previous OS pivot K  (higher high = trend continuation)
   if(crossedUp && rsi >= InpBuyAgain_Low && rsi <= InpBuyAgain_High)
   {
      if(lastOS_pivot > 0.0 && k1 > lastOS_pivot)
      {
         lastSignalTxt = "BUY AGAIN @ RSI " + DoubleToString(rsi, 1);
         pend.type     = SIG_BUY_AGAIN;
         pend.bar      = barTimes[1];
         pend.clr      = clrAqua;
         pend.arrow    = OBJ_ARROW_BUY;
         lastOS_pivot  = k1;
      }
      return;
   }
}

//+------------------------------------------------------------------+
//  CheckConfirmation – fire only when both TFs agree
//+------------------------------------------------------------------+
void CheckConfirmation()
{
   //--- Single-TF mode: bypass cross-TF requirement, fire directly
   if(!InpEnableTF1 || !InpEnableTF2)
   {
      if(InpEnableTF1 && g_pend_1.type != SIG_NONE)
      {
         string msg = SignalTypeName(g_pend_1.type) + " " + _Symbol;
         FireAlert(msg, g_pend_1.clr, g_pend_1.arrow, g_pend_1.bar);
         g_pend_1.Clear();
      }
      if(InpEnableTF2 && g_pend_2.type != SIG_NONE)
      {
         string msg = SignalTypeName(g_pend_2.type) + " " + _Symbol;
         FireAlert(msg, g_pend_2.clr, g_pend_2.arrow, g_pend_2.bar);
         g_pend_2.Clear();
      }
      return;
   }

   //--- Both TFs must have a pending signal
   if(g_pend_1.type == SIG_NONE || g_pend_2.type == SIG_NONE) return;

   //--- Signal types must match exactly
   if(g_pend_1.type != g_pend_2.type) return;

   //--- Signal bars must be within the confirmation window
   int gapSecs = (int)MathAbs((double)(g_pend_1.bar - g_pend_2.bar));
   if(gapSecs > InpConfirmMins * 60) return;

   //--- Both agree – fire once
   string msg = SignalTypeName(g_pend_1.type) + " " + _Symbol;
   datetime arrowBar = (g_pend_1.bar >= g_pend_2.bar) ? g_pend_1.bar : g_pend_2.bar;

   FireAlert(msg, g_pend_1.clr, g_pend_1.arrow, arrowBar);

   g_pend_1.Clear();
   g_pend_2.Clear();
}

//+------------------------------------------------------------------+
//  SignalTypeName
//+------------------------------------------------------------------+
string SignalTypeName(int sigType)
{
   switch(sigType)
   {
      case SIG_BUY:        return "BUY";
      case SIG_SELL:       return "SELL";
      case SIG_BUY_AGAIN:  return "BUY AGAIN";
      case SIG_SELL_AGAIN: return "SELL AGAIN";
   }
   return "";
}

//+------------------------------------------------------------------+
//  TFName – human-readable timeframe label
//+------------------------------------------------------------------+
string TFName(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

//+------------------------------------------------------------------+
//  FireAlert – dispatch notifications and draw arrow
//+------------------------------------------------------------------+
void FireAlert(string msg, color arrowClr, int arrowType, datetime barTime)
{
   if(InpEnablePush)
   {
      if(!SendNotification(msg))
         Print("Push notification failed. Ensure mobile terminal is linked.");
   }

   if(InpEnablePopup)
      Alert(msg);

   if(InpEnablePrint)
      Print(msg);

   if(InpDrawArrows)
      DrawSignalArrow(barTime, arrowType, arrowClr, msg);
}

//+------------------------------------------------------------------+
//  DrawSignalArrow
//+------------------------------------------------------------------+
void DrawSignalArrow(datetime arrowTime, int arrowCode, color clr, string tooltip)
{
   g_arrowCount++;
   string objName = StringFormat("StochRSI_Arrow_%d", g_arrowCount);

   int shift = iBarShift(_Symbol, PERIOD_CURRENT, arrowTime);
   if(shift < 0) return;

   double price = (arrowCode == OBJ_ARROW_BUY)
                  ? iLow (_Symbol, PERIOD_CURRENT, shift) * 0.9998
                  : iHigh(_Symbol, PERIOD_CURRENT, shift) * 1.0002;

   ObjectCreate(0, objName, (ENUM_OBJECT)arrowCode, 0, arrowTime, price);
   ObjectSetInteger(0, objName, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH,      2);
   ObjectSetString (0, objName, OBJPROP_TOOLTIP,    tooltip);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//  DrawDashboard
//+------------------------------------------------------------------+
void DrawDashboard()
{
   string tf1 = TFName(InpTF1);
   string tf2 = TFName(InpTF2);

   string pend1 = (g_pend_1.type != SIG_NONE)
                  ? SignalTypeName(g_pend_1.type) + " – waiting " + tf2 + "..."
                  : "–";
   string pend2 = (g_pend_2.type != SIG_NONE)
                  ? SignalTypeName(g_pend_2.type) + " – waiting " + tf1 + "..."
                  : "–";

   string dash = "\n"
      + "╔══════════════════════════════════════════╗\n"
      + "║  StochRSI MTF Alert  |  " + _Symbol + "\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  RSI(1)  OB: "
         + DoubleToString(InpRSI_OB_Low, 0) + "–" + DoubleToString(InpRSI_OB_High, 0)
         + "   OS: "
         + DoubleToString(InpRSI_OS_Low, 0) + "–" + DoubleToString(InpRSI_OS_High, 0) + "\n"
      + "║  Stoch(" + IntegerToString(InpStoch_K) + ","
                    + IntegerToString(InpStoch_D) + ","
                    + IntegerToString(InpStoch_Slow) + ")"
      + "  Confirm: " + IntegerToString(InpConfirmMins) + " min\n"
      + "║  TF1: " + tf1 + "   TF2: " + tf2 + "\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  " + tf1 + " Last  : " + g_last_signal_1 + "\n"
      + "║  " + tf1 + " OB Piv: " + (g_lastOB_pivot_1 > 0 ? DoubleToString(g_lastOB_pivot_1, 1) : "–") + "\n"
      + "║  " + tf1 + " OS Piv: " + (g_lastOS_pivot_1 > 0 ? DoubleToString(g_lastOS_pivot_1, 1) : "–") + "\n"
      + "║  " + tf1 + " Pend  : " + pend1 + "\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  " + tf2 + " Last  : " + g_last_signal_2 + "\n"
      + "║  " + tf2 + " OB Piv: " + (g_lastOB_pivot_2 > 0 ? DoubleToString(g_lastOB_pivot_2, 1) : "–") + "\n"
      + "║  " + tf2 + " OS Piv: " + (g_lastOS_pivot_2 > 0 ? DoubleToString(g_lastOS_pivot_2, 1) : "–") + "\n"
      + "║  " + tf2 + " Pend  : " + pend2 + "\n"
      + "╚══════════════════════════════════════════╝";

   Comment(dash);
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
