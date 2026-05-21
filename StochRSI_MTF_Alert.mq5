//+------------------------------------------------------------------+
//|                    StochRSI_MTF_Alert.mq5                        |
//|    Stochastic K/D Cross with RSI(1) Level Filter + Pivots        |
//|    Multi-Timeframe: M4 / M6                                      |
//|                                                                  |
//|  SIGNAL LOGIC:                                                   |
//|   BUY       – K crosses D UP   while RSI in OS zone  (1–8)       |
//|   SELL      – K crosses D DOWN while RSI in OB zone  (90–98)     |
//|   BUY AGAIN – K crosses D UP   while RSI in 15–40               |
//|               AND cross K level > last BUY pivot                 |
//|   SELL AGAIN– K crosses D DOWN while RSI in 60–80               |
//|               AND cross K level < last SELL pivot                |
//+------------------------------------------------------------------+
#property copyright   "Custom Indicator"
#property version     "1.10"
#property description "Stoch K/D cross filtered by RSI(1) level – M4/M6 multi-TF push alerts"
#property indicator_chart_window
#property indicator_plots 0

//════════════════════════════════════════════════════════════════════
//  INPUT PARAMETERS
//════════════════════════════════════════════════════════════════════
input group "══════ RSI Settings ══════"
input int    InpRSI_Period       = 1;      // RSI Period (use 1 for raw OB/OS)
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
input bool   InpEnablePush       = true;  // Send Push Notification
input bool   InpEnablePopup      = false; // Show Alert Popup
input bool   InpEnablePrint      = true;  // Print to Journal

input group "══════ Display Settings ══════"
input bool   InpDrawArrows       = true;  // Draw signal arrows on chart
input bool   InpShowDashboard    = true;  // Show info dashboard

//════════════════════════════════════════════════════════════════════
//  CONSTANTS & GLOBALS
//════════════════════════════════════════════════════════════════════

// Indicator handles – M4
int g_h_rsi_m4   = INVALID_HANDLE;
int g_h_stoch_m4 = INVALID_HANDLE;

// Indicator handles – M6
int g_h_rsi_m6   = INVALID_HANDLE;
int g_h_stoch_m6 = INVALID_HANDLE;

// Last processed bar timestamps
datetime g_lastBar_m4 = 0;
datetime g_lastBar_m6 = 0;

//--- Pivot memory (K value at last primary signal)
double g_lastOB_pivot_m4 = -1.0;   // Last SELL cross K value – M4
double g_lastOS_pivot_m4 = -1.0;   // Last BUY  cross K value – M4
double g_lastOB_pivot_m6 = -1.0;   // Last SELL cross K value – M6
double g_lastOS_pivot_m6 = -1.0;   // Last BUY  cross K value – M6

//--- Last signal text for dashboard
string g_last_signal_m4 = "–";
string g_last_signal_m6 = "–";

//--- Arrow counter (unique object names)
int g_arrowCount = 0;

//+------------------------------------------------------------------+
//  INIT
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Create indicator handles
   g_h_rsi_m4   = iRSI      (_Symbol, PERIOD_M4, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_m4 = iStochastic(_Symbol, PERIOD_M4, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);

   g_h_rsi_m6   = iRSI      (_Symbol, PERIOD_M6, InpRSI_Period, PRICE_CLOSE);
   g_h_stoch_m6 = iStochastic(_Symbol, PERIOD_M6, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);

   //--- Validate
   if(g_h_rsi_m4   == INVALID_HANDLE){ Alert("StochRSI: Failed to create RSI M4 handle");   return INIT_FAILED; }
   if(g_h_stoch_m4 == INVALID_HANDLE){ Alert("StochRSI: Failed to create Stoch M4 handle"); return INIT_FAILED; }
   if(g_h_rsi_m6   == INVALID_HANDLE){ Alert("StochRSI: Failed to create RSI M6 handle");   return INIT_FAILED; }
   if(g_h_stoch_m6 == INVALID_HANDLE){ Alert("StochRSI: Failed to create Stoch M6 handle"); return INIT_FAILED; }

   //--- Brief wait so MT5 starts populating buffers
   EventSetTimer(2);

   Print("StochRSI MTF Alert loaded on ", _Symbol,
         " | RSI(", InpRSI_Period, ")",
         " | Stoch(", InpStoch_K, ",", InpStoch_D, ",", InpStoch_Slow, ")",
         " | M4:", InpEnableM4, " M6:", InpEnableM6);

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

   //--- Remove dashboard label
   ObjectDelete(0, "StochRSI_Dashboard");
   Comment("");
}

//+------------------------------------------------------------------+
//  TIMER – re-run on timer to catch bars that form off-chart TF
//+------------------------------------------------------------------+
void OnTimer()
{
   CheckAllTimeframes();
}

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
//  CheckAllTimeframes – entry point for both TFs
//+------------------------------------------------------------------+
void CheckAllTimeframes()
{
   if(InpEnableM4)
      ProcessTimeframe(PERIOD_M4,
                       g_h_rsi_m4, g_h_stoch_m4,
                       g_lastBar_m4,
                       g_lastOB_pivot_m4, g_lastOS_pivot_m4,
                       g_last_signal_m4,
                       "M4");

   if(InpEnableM6)
      ProcessTimeframe(PERIOD_M6,
                       g_h_rsi_m6, g_h_stoch_m6,
                       g_lastBar_m6,
                       g_lastOB_pivot_m6, g_lastOS_pivot_m6,
                       g_last_signal_m6,
                       "M6");

   if(InpShowDashboard)
      DrawDashboard();
}

//+------------------------------------------------------------------+
//  ProcessTimeframe – core detection logic
//+------------------------------------------------------------------+
void ProcessTimeframe(ENUM_TIMEFRAMES tf,
                      int             h_rsi,
                      int             h_stoch,
                      datetime       &lastBar,
                      double         &lastOB_pivot,
                      double         &lastOS_pivot,
                      string         &lastSignalTxt,
                      string          tfName)
{
   //--- Get last 2 completed bar timestamps
   datetime barTimes[3];
   if(CopyTime(_Symbol, tf, 0, 3, barTimes) < 3) return;

   //--- Only act once per NEW completed bar  [0]=open, [1]=last closed, [2]=prior
   if(barTimes[1] == lastBar) return;
   lastBar = barTimes[1];

   //--- Pull 3 values: [0]=forming, [1]=last complete, [2]=prior complete
   double rsi_buf[3], k_buf[3], d_buf[3];

   if(CopyBuffer(h_rsi,   0,           0, 3, rsi_buf) < 3) return;
   if(CopyBuffer(h_stoch, MAIN_LINE,   0, 3, k_buf)   < 3) return;
   if(CopyBuffer(h_stoch, SIGNAL_LINE, 0, 3, d_buf)   < 3) return;

   //--- Confirmed values on the last CLOSED bar  ──────────────────
   double rsi = rsi_buf[1];   // RSI of last closed bar
   double k1  = k_buf[1];     // K of last closed bar
   double d1  = d_buf[1];     // D of last closed bar
   double k2  = k_buf[2];     // K of bar before that
   double d2  = d_buf[2];     // D of bar before that

   //--- Crossover detection
   bool crossedUp   = (k2 <= d2) && (k1 > d1);
   bool crossedDown = (k2 >= d2) && (k1 < d1);

   if(!crossedUp && !crossedDown) return;   // No cross – nothing to do

   //--- ══ PRIMARY BUY ══════════════════════════════════════════════
   //    K crosses D upward while RSI is in OS zone
   if(crossedUp && rsi >= InpRSI_OS_Low && rsi <= InpRSI_OS_High)
   {
      lastOS_pivot   = k1;   // Record pivot for BUY AGAIN filter
      string msg     = BuildMsg("BUY", tfName, rsi, k1, d1, -1);
      lastSignalTxt  = "BUY @ RSI " + DoubleToString(rsi, 1);
      FireAlert(msg, clrLime, OBJ_ARROW_BUY, barTimes[1]);
      return;
   }

   //--- ══ PRIMARY SELL ══════════════════════════════════════════════
   //    K crosses D downward while RSI is in OB zone
   if(crossedDown && rsi >= InpRSI_OB_Low && rsi <= InpRSI_OB_High)
   {
      lastOB_pivot   = k1;   // Record pivot for SELL AGAIN filter
      string msg     = BuildMsg("SELL", tfName, rsi, k1, d1, -1);
      lastSignalTxt  = "SELL @ RSI " + DoubleToString(rsi, 1);
      FireAlert(msg, clrRed, OBJ_ARROW_SELL, barTimes[1]);
      return;
   }

   //--- ══ SELL AGAIN ════════════════════════════════════════════════
   //    K crosses D downward in the 60–80 RSI zone
   //    Pivot condition: current cross K < previous OB pivot K  (lower high = trend continuation)
   if(crossedDown && rsi >= InpSellAgain_Low && rsi <= InpSellAgain_High)
   {
      if(lastOB_pivot > 0.0 && k1 < lastOB_pivot)
      {
         string msg    = BuildMsg("SELL AGAIN", tfName, rsi, k1, d1, lastOB_pivot);
         lastSignalTxt = "SELL AGAIN @ RSI " + DoubleToString(rsi, 1);
         FireAlert(msg, clrOrangeRed, OBJ_ARROW_SELL, barTimes[1]);
         lastOB_pivot  = k1;   // Update pivot to keep tracking new lows
      }
      return;
   }

   //--- ══ BUY AGAIN ═════════════════════════════════════════════════
   //    K crosses D upward in the 15–40 RSI zone
   //    Pivot condition: current cross K > previous OS pivot K  (higher low = trend continuation)
   if(crossedUp && rsi >= InpBuyAgain_Low && rsi <= InpBuyAgain_High)
   {
      if(lastOS_pivot > 0.0 && k1 > lastOS_pivot)
      {
         string msg    = BuildMsg("BUY AGAIN", tfName, rsi, k1, d1, lastOS_pivot);
         lastSignalTxt = "BUY AGAIN @ RSI " + DoubleToString(rsi, 1);
         FireAlert(msg, clrAqua, OBJ_ARROW_BUY, barTimes[1]);
         lastOS_pivot  = k1;   // Update pivot to keep tracking new highs
      }
      return;
   }
}

//+------------------------------------------------------------------+
//  BuildMsg – format the notification text
//+------------------------------------------------------------------+
string BuildMsg(string signalType,
                string tfName,
                double rsi,
                double k,
                double d,
                double pivot)
{
   string pivotStr = (pivot >= 0.0)
                     ? StringFormat(" | Pivot=%.1f", pivot)
                     : "";

   return StringFormat("[%s] %s %s | RSI(1)=%.1f | K=%.1f D=%.1f%s",
                       signalType, _Symbol, tfName,
                       rsi, k, d,
                       pivotStr);
}

//+------------------------------------------------------------------+
//  FireAlert – dispatch notifications and draw arrow
//+------------------------------------------------------------------+
void FireAlert(string msg, color arrowClr, int arrowType, datetime barTime)
{
   //--- Push notification to MetaTrader mobile app
   if(InpEnablePush)
   {
      if(!SendNotification(msg))
         Print("Push notification failed. Ensure mobile terminal is linked.");
   }

   //--- Popup alert in terminal
   if(InpEnablePopup)
      Alert(msg);

   //--- Journal log
   if(InpEnablePrint)
      Print(msg);

   //--- Arrow on chart (only when chart TF matches or for visual overlay)
   if(InpDrawArrows)
      DrawSignalArrow(barTime, arrowType, arrowClr, msg);
}

//+------------------------------------------------------------------+
//  DrawSignalArrow – place a buy/sell arrow on the main chart
//+------------------------------------------------------------------+
void DrawSignalArrow(datetime arrowTime, int arrowCode, color clr, string tooltip)
{
   g_arrowCount++;
   string objName = StringFormat("StochRSI_Arrow_%d", g_arrowCount);

   double price = (arrowCode == OBJ_ARROW_BUY)
                  ? iLow (_Symbol, PERIOD_CURRENT, iBarShift(_Symbol, PERIOD_CURRENT, arrowTime)) * 0.9998
                  : iHigh(_Symbol, PERIOD_CURRENT, iBarShift(_Symbol, PERIOD_CURRENT, arrowTime)) * 1.0002;

   ObjectCreate(0, objName, (ENUM_OBJECT)arrowCode, 0, arrowTime, price);
   ObjectSetInteger(0, objName, OBJPROP_COLOR,  clr);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH,  2);
   ObjectSetString (0, objName, OBJPROP_TOOLTIP, tooltip);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//  DrawDashboard – chart comment showing current state
//+------------------------------------------------------------------+
void DrawDashboard()
{
   string dash = "\n"
      + "╔══════════════════════════════════════════╗\n"
      + "║     StochRSI MTF Alert  |  " + _Symbol + "        ║\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  RSI(" + IntegerToString(InpRSI_Period) + ")   OB: "
         + DoubleToString(InpRSI_OB_Low,  0) + "–" + DoubleToString(InpRSI_OB_High, 0)
         + "   OS: "
         + DoubleToString(InpRSI_OS_Low,  0) + "–" + DoubleToString(InpRSI_OS_High, 0)
         + "     ║\n"
      + "║  Stoch(" + IntegerToString(InpStoch_K) + "," + IntegerToString(InpStoch_D) + "," + IntegerToString(InpStoch_Slow) + ")                              ║\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  M4 Last Signal : " + g_last_signal_m4 + "\n"
      + "║  M4 OB Pivot    : " + (g_lastOB_pivot_m4 > 0 ? DoubleToString(g_lastOB_pivot_m4,1) : "–") + "\n"
      + "║  M4 OS Pivot    : " + (g_lastOS_pivot_m4 > 0 ? DoubleToString(g_lastOS_pivot_m4,1) : "–") + "\n"
      + "╠══════════════════════════════════════════╣\n"
      + "║  M6 Last Signal : " + g_last_signal_m6 + "\n"
      + "║  M6 OB Pivot    : " + (g_lastOB_pivot_m6 > 0 ? DoubleToString(g_lastOB_pivot_m6,1) : "–") + "\n"
      + "║  M6 OS Pivot    : " + (g_lastOS_pivot_m6 > 0 ? DoubleToString(g_lastOS_pivot_m6,1) : "–") + "\n"
      + "╚══════════════════════════════════════════╝";

   Comment(dash);
}

//+------------------------------------------------------------------+
//  END OF FILE
//+------------------------------------------------------------------+
