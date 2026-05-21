//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with RSI(1) Level Filter + Pivots        |
//|    Multi-Timeframe: M4 / M6  –  BOTH MUST AGREE                 |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   BUY       – K crosses D UP   while RSI in OS zone  (1–8)       |
//|   SELL      – K crosses D DOWN while RSI in OB zone  (90–98)     |
//|   BUY AGAIN – K crosses D UP   while RSI in 15–40               |
//|               AND cross K level > last BUY pivot  (higher high)  |
//|   SELL AGAIN– K crosses D DOWN while RSI in 60–80               |
//|               AND cross K level < last SELL pivot (lower low)    |
//|                                                                  |
//|  CONFIRMATION: alert fires only when M4 AND M6 detect the same   |
//|  signal type within InpConfirmMins of each other.                |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "1.20"
#property description "Stoch K/D cross filtered by RSI(1) level – M4+M6 confirmed alerts"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ RSI Settings ══════"
input int    InpRSI_Period       = 1;      // RSI Period
input double InpRSI_OB_High      = 98.0;  // OB Upper Bound
input double InpRSI_OB_Low       = 90.0;  // OB Lower Bound
input double InpRSI_OS_High      = 8.0;   // OS Upper Bound
input double InpRSI_OS_Low       = 1.0;   // OS Lower Bound

input group "══════ Stochastic Settings ══════"
input int    InpStoch_K          = 50;    // %K Period
input int    InpStoch_D          = 7;     // %D Period (signal)
input int    InpStoch_Slow       = 11;    // Slowing

input group "══════ Re-Entry Zone Filters ══════"
input double InpSellAgain_High   = 80.0;  // Sell-Again RSI upper
input double InpSellAgain_Low    = 60.0;  // Sell-Again RSI lower
input double InpBuyAgain_High    = 40.0;  // Buy-Again RSI upper
input double InpBuyAgain_Low     = 15.0;  // Buy-Again RSI lower

input group "══════ Timeframe Selection ══════"
input bool   InpEnableM4         = true;  // Monitor M4
input bool   InpEnableM6         = true;  // Monitor M6

input group "══════ Notification Settings ══════"
input int    InpConfirmMins      = 12;    // Confirmation window (minutes) – max gap between M4 and M6 signal bars
input bool   InpEnablePush       = true;  // Send Push Notification
input bool   InpEnablePopup      = false; // Show Alert Popup
input bool   InpEnablePrint      = true;  // Print to Journal

input group "══════ Display Settings ══════"
input bool   InpDrawArrows       = true;  // Draw signal arrows on chart
input bool   InpShowDashboard    = true;  // Show info dashboard

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
   int      type;      // SIG_* constant
   datetime bar;       // closed bar time that generated the signal
   color    clr;       // arrow / display colour
   int      arrow;     // OBJ_ARROW_BUY or OBJ_ARROW_SELL
   string   details;   // "M4 RSI(1)=X K=Y D=Z [Piv=P]"

   void Clear()
   {
      type    = SIG_NONE;
      bar     = 0;
      clr     = clrNONE;
      arrow   = 0;
      details = "";
   }
};

//════════════════════════════════════════════════════════════════════
//  GLOBALS
//════════════════════════════════════════════════════════════════════

// Indicator handles
int g_h_rsi_m4   = INVALID_HANDLE;
int g_h_stoch_m4 = INVALID_HANDLE;
int g_h_rsi_m6   = INVALID_HANDLE;
int g_h_stoch_m6 = INVALID_HANDLE;

// Last processed bar timestamps (per TF)
datetime g_lastBar_m4 = 0;
datetime g_lastBar_m6 = 0;

// Pivot memory – K value at last primary signal (per TF)
double g_lastOB_pivot_m4 = -1.0;
double g_lastOS_pivot_m4 = -1.0;
double g_lastOB_pivot_m6 = -1.0;
double g_lastOS_pivot_m6 = -1.0;

// Last signal text for dashboard (per TF)
string g_last_signal_m4 = "–";
string g_last_signal_m6 = "–";

// Arrow counter
int g_arrowCount = 0;

// Pending signals – each TF stores its latest detection here;
// a confirmed alert fires only when both agree on the same type
PendingSignal g_pend_m4;
PendingSignal g_pend_m6;

//+------------------------------------------------------------------+
//  INIT
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Reset all state (safe across parameter changes)
   g_lastBar_m4 = g_lastBar_m6 = 0;
   g_lastOB_pivot_m4 = g_lastOS_pivot_m4 = -1.0;
   g_lastOB_pivot_m6 = g_lastOS_pivot_m6 = -1.0;
   g_last_signal_m4  = g_last_signal_m6  = "–";
   g_arrowCount = 0;
   g_pend_m4.Clear();
   g_pend_m6.Clear();

   //--- Create indicator handles
   g_h_rsi_m4   = iRSI       (_Symbol, PERIOD_M4, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_m4 = iStochastic(_Symbol, PERIOD_M4, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   g_h_rsi_m6   = iRSI       (_Symbol, PERIOD_M6, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_m6 = iStochastic(_Symbol, PERIOD_M6, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);

   if(g_h_rsi_m4   == INVALID_HANDLE){ Alert("StochRSI: Failed to create RSI M4 handle");   return INIT_FAILED; }
   if(g_h_stoch_m4 == INVALID_HANDLE){ Alert("StochRSI: Failed to create Stoch M4 handle"); return INIT_FAILED; }
   if(g_h_rsi_m6   == INVALID_HANDLE){ Alert("StochRSI: Failed to create RSI M6 handle");   return INIT_FAILED; }
   if(g_h_stoch_m6 == INVALID_HANDLE){ Alert("StochRSI: Failed to create Stoch M6 handle"); return INIT_FAILED; }

   //--- Recurring 2-second timer to catch bars that form on off-chart TFs
   EventSetTimer(2);

   Print("StochRSI MTF Alert loaded  ", _Symbol,
         " | Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | M4:", InpEnableM4, " M6:", InpEnableM6,
         " | ConfirmWindow:", InpConfirmMins, "min");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//  DEINIT
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(g_h_rsi_m4   != INVALID_HANDLE) IndicatorRelease(g_h_rsi_m4);
   if(g_h_stoch_m4 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_m4);
   if(g_h_rsi_m6   != INVALID_HANDLE) IndicatorRelease(g_h_rsi_m6);
   if(g_h_stoch_m6 != INVALID_HANDLE) IndicatorRelease(g_h_stoch_m6);

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
   if(InpEnableM4)
      ProcessTimeframe(PERIOD_M4,
                       g_h_rsi_m4, g_h_stoch_m4,
                       g_lastBar_m4,
                       g_lastOB_pivot_m4, g_lastOS_pivot_m4,
                       g_last_signal_m4, "M4",
                       g_pend_m4);

   if(InpEnableM6)
      ProcessTimeframe(PERIOD_M6,
                       g_h_rsi_m6, g_h_stoch_m6,
                       g_lastBar_m6,
                       g_lastOB_pivot_m6, g_lastOS_pivot_m6,
                       g_last_signal_m6, "M6",
                       g_pend_m6);

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
                      string           tfName,
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
      pend.details  = BuildDetails(tfName, rsi, k1, d1, -1);
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
      pend.details  = BuildDetails(tfName, rsi, k1, d1, -1);
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
         pend.details  = BuildDetails(tfName, rsi, k1, d1, lastOB_pivot);
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
         pend.details  = BuildDetails(tfName, rsi, k1, d1, lastOS_pivot);
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
   if(!InpEnableM4 || !InpEnableM6)
   {
      if(InpEnableM4 && g_pend_m4.type != SIG_NONE)
      {
         string msg = StringFormat("[%s] %s M4 | %s",
                                   SignalTypeName(g_pend_m4.type), _Symbol, g_pend_m4.details);
         FireAlert(msg, g_pend_m4.clr, g_pend_m4.arrow, g_pend_m4.bar);
         g_pend_m4.Clear();
      }
      if(InpEnableM6 && g_pend_m6.type != SIG_NONE)
      {
         string msg = StringFormat("[%s] %s M6 | %s",
                                   SignalTypeName(g_pend_m6.type), _Symbol, g_pend_m6.details);
         FireAlert(msg, g_pend_m6.clr, g_pend_m6.arrow, g_pend_m6.bar);
         g_pend_m6.Clear();
      }
      return;
   }

   //--- Both TFs must have a pending signal
   if(g_pend_m4.type == SIG_NONE || g_pend_m6.type == SIG_NONE) return;

   //--- Signal types must match exactly
   if(g_pend_m4.type != g_pend_m6.type) return;

   //--- Signal bars must be within the confirmation window
   int gapSecs = (int)MathAbs((double)(g_pend_m4.bar - g_pend_m6.bar));
   if(gapSecs > InpConfirmMins * 60) return;

   //--- Both agree – build confirmed message and fire once
   string sigName = SignalTypeName(g_pend_m4.type);
   string msg = StringFormat("[%s CONFIRMED] %s M4+M6 | %s | %s",
                              sigName, _Symbol,
                              g_pend_m4.details, g_pend_m6.details);

   //--- Arrow on the more recent of the two signal bars
   datetime arrowBar = (g_pend_m4.bar >= g_pend_m6.bar) ? g_pend_m4.bar : g_pend_m6.bar;

   FireAlert(msg, g_pend_m4.clr, g_pend_m4.arrow, arrowBar);

   g_pend_m4.Clear();
   g_pend_m6.Clear();
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
//  BuildDetails – compact per-TF info string stored in pending
//+------------------------------------------------------------------+
string BuildDetails(string tfName, double rsi, double k, double d, double pivot)
{
   string pivStr = (pivot >= 0.0) ? StringFormat(" Piv=%.1f", pivot) : "";
   return StringFormat("%s RSI(1)=%.1f K=%.1f D=%.1f%s", tfName, rsi, k, d, pivStr);
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
   string m4pend = (g_pend_m4.type != SIG_NONE)
                   ? SignalTypeName(g_pend_m4.type) + " – waiting M6..."
                   : "–";
   string m6pend = (g_pend_m6.type != SIG_NONE)
                   ? SignalTypeName(g_pend_m6.type) + " – waiting M4..."
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
      + "╠══════════════════════════════════════════╣\n"
      + "║  M4 Last  : " + g_last_signal_m4 + "\n"
      + "║  M4 OB Piv: " + (g_lastOB_pivot_m4 > 0 ? DoubleToString(g_lastOB_pivot_m4, 1) : "–") + "\n"
      + "║  M4 OS Piv: " + (g_lastOS_pivot_m4 > 0 ? DoubleToString(g_lastOS_pivot_m4, 1) : "–") + "\n"
      + "║  M4 Pend  : " + m4pend + "\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  M6 Last  : " + g_last_signal_m6 + "\n"
      + "║  M6 OB Piv: " + (g_lastOB_pivot_m6 > 0 ? DoubleToString(g_lastOB_pivot_m6, 1) : "–") + "\n"
      + "║  M6 OS Piv: " + (g_lastOS_pivot_m6 > 0 ? DoubleToString(g_lastOS_pivot_m6, 1) : "–") + "\n"
      + "║  M6 Pend  : " + m6pend + "\n"
      + "╚══════════════════════════════════════════╝";

   Comment(dash);
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
