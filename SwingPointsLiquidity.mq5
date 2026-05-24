//+------------------------------------------------------------------+
//|                                       SwingPointsLiquidity.mq5  |
//|          Port of "Swing Points and Liquidity" by LeviathanCap.  |
//|          + Market Structure (HH / HL / LH / LL)                 |
//|          + CHoCH / MSS Detection + Trend-State Signals          |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.10"
#property indicator_chart_window
#property indicator_plots 6

//--- Plot 0 : With-trend BUY  (HL in bull trend)
#property indicator_label1  "BUY (With-Trend)"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  2

//--- Plot 1 : Counter-trend BUY  (HL in bear trend)
#property indicator_label2  "BUY (Counter-Trend)"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  C'0,120,60'
#property indicator_width2  1

//--- Plot 2 : With-trend SELL  (LH in bear trend)
#property indicator_label3  "SELL (With-Trend)"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrCrimson
#property indicator_width3  2

//--- Plot 3 : Counter-trend SELL  (LH in bull trend)
#property indicator_label4  "SELL (Counter-Trend)"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  C'130,40,50'
#property indicator_width4  1

//--- Plot 4 : CHoCH Bullish dot
#property indicator_label5  "CHoCH Bull"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrDeepSkyBlue
#property indicator_width5  2

//--- Plot 5 : CHoCH Bearish dot
#property indicator_label6  "CHoCH Bear"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrOrangeRed
#property indicator_width6  2

// ================================================================
// INPUTS
// ================================================================
input group "=== Swing Detection ==="
input int    InpSwingRight   = 10;               // Bars Right
input int    InpSwingLeft    = 15;               // Bars Left

input group "=== Display ==="
input bool   InpShowBoxes    = true;             // Show Liquidity Boxes
input bool   InpShowLines    = true;             // Show Level Lines
input bool   InpShowDots     = true;             // Show Signal Dots
input bool   InpShowCTSig    = true;             // Show Counter-Trend Signals
input bool   InpExtendFill   = true;             // Extend Until Filled
input bool   InpHideFilled   = false;            // Hide Filled Levels

input group "=== Appearance ==="
input color  InpHighColor    = C'170,36,48';     // Swing High Colour
input color  InpLowColor     = C'102,187,106';   // Swing Low Colour
input ENUM_LINE_STYLE InpLineStyle = STYLE_DOT;  // Line Style
input int    InpLineWidth    = 1;                // Line Width
input double InpBoxWidth     = 0.7;              // Box Width % (0.1-2.0)

input group "=== Market Structure ==="
input bool   InpShowMSS      = true;             // Draw CHoCH Label on Chart
input color  InpMSSBullCol   = clrDeepSkyBlue;   // CHoCH → Bullish colour
input color  InpMSSBearCol   = clrOrangeRed;     // CHoCH → Bearish colour

input group "=== Alerts & Push ==="
input bool   InpAlerts       = true;             // Pop-up Alerts
input bool   InpPush         = true;             // Push Notifications (mobile)
input bool   InpOnlyNewBar   = true;             // Fire alert only on bar close

// ================================================================
// BUFFERS
// ================================================================
double BufBuyWT[];    // with-trend  BUY   (HL in bull)
double BufBuyCT[];    // counter-trd BUY   (HL in bear)
double BufSellWT[];   // with-trend  SELL  (LH in bear)
double BufSellCT[];   // counter-trd SELL  (LH in bull)
double BufChochB[];   // CHoCH bullish dot
double BufChochBr[];  // CHoCH bearish dot

// ================================================================
// CONSTANTS / GLOBALS
// ================================================================
const string PFX         = "SPL_";
const int    MAX_OBJECTS = 500;

//--- Level tracking (liquidity lines / boxes)
struct SLevel
  {
   double   price;
   double   boxTop;
   double   boxBot;
   datetime t1;
   bool     isHigh;
   string   lineName;
   string   boxName;
  };

SLevel   g_lv[];
int      g_nLv = 0;

//--- Market-structure state
double   g_lastPH    = 0;
double   g_lastPL    = 0;
int      g_lastPHBar = -1;
int      g_lastPLBar = -1;
int      g_trend     = 0;   // 0=undef  1=bull  -1=bear

//--- Alert dedup : track last bar index that fired an alert
int      g_lastAlertBar = -1;

// ================================================================
// OnInit
// ================================================================
int OnInit()
  {
   SetIndexBuffer(0, BufBuyWT,   INDICATOR_DATA);
   SetIndexBuffer(1, BufBuyCT,   INDICATOR_DATA);
   SetIndexBuffer(2, BufSellWT,  INDICATOR_DATA);
   SetIndexBuffer(3, BufSellCT,  INDICATOR_DATA);
   SetIndexBuffer(4, BufChochB,  INDICATOR_DATA);
   SetIndexBuffer(5, BufChochBr, INDICATOR_DATA);

   // Arrow codes (Wingdings)
   PlotIndexSetInteger(0, PLOT_ARROW, 233);  // ▲ up   - with-trend buy
   PlotIndexSetInteger(1, PLOT_ARROW, 233);  // ▲ up   - counter-trend buy (dimmer colour)
   PlotIndexSetInteger(2, PLOT_ARROW, 234);  // ▼ down - with-trend sell
   PlotIndexSetInteger(3, PLOT_ARROW, 234);  // ▼ down - counter-trend sell (dimmer)
   PlotIndexSetInteger(4, PLOT_ARROW, 159);  // ● circle - CHoCH bull
   PlotIndexSetInteger(5, PLOT_ARROW, 159);  // ● circle - CHoCH bear

   // Arrow shifts: buy arrow below bar, sell arrow above bar
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT,  12);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT,  12);
   PlotIndexSetInteger(3, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT, -12);

   for(int p = 0; p < 6; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, 0.0);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("SP&L (%d/%d)", InpSwingLeft, InpSwingRight));

   return INIT_SUCCEEDED;
  }

// ================================================================
// OnDeinit
// ================================================================
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
  }

// ================================================================
// HELPERS : pivot detection
// Arrays are NOT time-series (index 0 = oldest bar).
// ================================================================
bool IsPivotHigh(const double &h[], int pos, int left, int right, int total)
  {
   if(pos - left < 0 || pos + right >= total) return false;
   double v = h[pos];
   for(int k = 1; k <= left;  k++) if(h[pos - k] >= v) return false;
   for(int k = 1; k <= right; k++) if(h[pos + k] >= v) return false;
   return true;
  }

bool IsPivotLow(const double &l[], int pos, int left, int right, int total)
  {
   if(pos - left < 0 || pos + right >= total) return false;
   double v = l[pos];
   for(int k = 1; k <= left;  k++) if(l[pos - k] <= v) return false;
   for(int k = 1; k <= right; k++) if(l[pos + k] <= v) return false;
   return true;
  }

// ================================================================
// HELPERS : object drawing
// ================================================================
void DrawLine(const string &name, double price,
              datetime t1, datetime t2, color col)
  {
   if(!InpShowLines) return;
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      col);
      ObjectSetInteger(0, name, OBJPROP_STYLE,      InpLineStyle);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      InpLineWidth);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 1, price);
     }
  }

void DrawBox(const string &name, double top, double bot,
             datetime t1, datetime t2, color col)
  {
   if(!InpShowBoxes) return;
   color dim = (color)(((int)(((col >> 16) & 0xFF) * 0.22) << 16) |
                       ((int)(((col >>  8) & 0xFF) * 0.22) <<  8) |
                        (int)((col         & 0xFF) * 0.22));
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, top, t2, bot);
      ObjectSetInteger(0, name, OBJPROP_COLOR,       dim);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     dim);
      ObjectSetInteger(0, name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,      true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 0, top);
      ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 1, bot);
     }
  }

void DrawChochLabel(const string &name, const string &txt,
                    datetime t, double price, color col, bool above)
  {
   if(!InpShowMSS) return;
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT,       txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     above ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   8);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

// ================================================================
// HELPERS : level array management
// ================================================================
void AddLevel(double price, double top, double bot,
              datetime t1, bool isHigh,
              const string &ln, const string &bx)
  {
   ArrayResize(g_lv, g_nLv + 1);
   g_lv[g_nLv].price    = price;
   g_lv[g_nLv].boxTop   = top;
   g_lv[g_nLv].boxBot   = bot;
   g_lv[g_nLv].t1       = t1;
   g_lv[g_nLv].isHigh   = isHigh;
   g_lv[g_nLv].lineName = ln;
   g_lv[g_nLv].boxName  = bx;
   g_nLv++;
  }

void RemoveLevel(int i)
  {
   if(i < 0 || i >= g_nLv) return;
   ObjectDelete(0, g_lv[i].lineName);
   ObjectDelete(0, g_lv[i].boxName);
   g_lv[i] = g_lv[g_nLv - 1];
   g_nLv--;
   ArrayResize(g_lv, g_nLv);
  }

// ================================================================
// HELPER : alert / push
// ================================================================
string TrendLabel(int trend)
  {
   if(trend ==  1) return "Bullish";
   if(trend == -1) return "Bearish";
   return "Undefined";
  }

string PeriodStr()
  {
   switch(_Period)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
      default:         return "TF?";
     }
  }

void FireAlert(const string &msg, int confirmBar)
  {
   if(!InpAlerts && !InpPush) return;
   if(g_lastAlertBar == confirmBar) return;  // already fired this bar
   g_lastAlertBar = confirmBar;
   if(InpAlerts)  Alert(msg);
   if(InpPush)    SendNotification(msg);
  }

// ================================================================
// HELPER : reset for full recalculation
// ================================================================
void ResetAll()
  {
   ObjectsDeleteAll(0, PFX);
   ArrayResize(g_lv, 0);
   g_nLv        = 0;
   g_lastPH     = 0;  g_lastPHBar = -1;
   g_lastPL     = 0;  g_lastPLBar = -1;
   g_trend      = 0;
   g_lastAlertBar = -1;
  }

// ================================================================
// SIGNAL + STRUCTURE LOGIC  (called once per confirmed pivot)
//
//  isHigh  = true → pivot high (potential LH/HH)
//  price   = high[pivBar] or low[pivBar]
//  pivBar  = absolute bar index of the pivot (0=oldest)
//  confirmBar = bar where pivot was confirmed (pivBar + InpSwingRight)
//  isLive  = confirmation happened on the live bar (alert eligible)
// ================================================================
void ProcessPivot(bool isHigh, double price, int pivBar, int confirmBar,
                  bool isLive, const datetime &time[],
                  double &bufWT[], double &bufCT[],
                  double &bufChochBull[], double &bufChochBear[])
  {
   string sym  = _Symbol;
   string tf   = PeriodStr();
   string tLbl = TrendLabel(g_trend);

   if(isHigh)
     {
      // --- Classify the pivot high against last known high ---
      bool isHH = (g_lastPH == 0 || price > g_lastPH);
      bool isLH = (g_lastPH != 0 && price < g_lastPH);

      if(isHH && g_trend == -1)
        {
         // ── CHoCH: bearish → bullish ───────────────────────────
         DrawChochLabel(PFX + "CHoCH_" + IntegerToString(pivBar),
                        "CHoCH", time[pivBar], price, InpMSSBullCol, false);
         bufChochBull[pivBar] = price;
         g_trend = 1;

         if(isLive)
            FireAlert(sym + " " + tf +
                      " | ⚡ CHoCH → Trend flipped BULLISH @ " +
                      DoubleToString(price, _Digits), confirmBar);
        }
      else if(isHH && g_trend == 0)
         g_trend = 1;
      else if(isLH && g_trend == 1)
         g_trend = -1;
      else if(isLH && g_trend == 0)
         g_trend = -1;

      // Update last pivot high
      if(g_lastPH == 0 || price != g_lastPH)
        { g_lastPH = price;  g_lastPHBar = pivBar; }

      // ── SELL Signal on every confirmed LH ────────────────────
      if(isLH && InpShowDots)
        {
         bool withTrend = (g_trend == -1);  // LH in bear = with-trend sell
         if(withTrend)
           {
            bufWT[pivBar] = price;
            if(isLive)
               FireAlert(sym + " " + tf +
                         " | 🔴 SELL  @ " + DoubleToString(price, _Digits) +
                         "  | Trend: Bearish (With-Trend)", confirmBar);
           }
         else if(InpShowCTSig)
           {
            bufCT[pivBar] = price;
            if(isLive)
               FireAlert(sym + " " + tf +
                         " | 🟠 SELL  @ " + DoubleToString(price, _Digits) +
                         "  | Trend: " + tLbl + " (Counter-Trend)", confirmBar);
           }
        }
     }
   else // pivot low
     {
      // --- Classify the pivot low against last known low ---
      bool isLL = (g_lastPL == 0 || price < g_lastPL);
      bool isHL = (g_lastPL != 0 && price > g_lastPL);

      if(isLL && g_trend == 1)
        {
         // ── CHoCH: bullish → bearish ───────────────────────────
         DrawChochLabel(PFX + "CHoCH_" + IntegerToString(pivBar),
                        "CHoCH", time[pivBar], price, InpMSSBearCol, true);
         bufChochBear[pivBar] = price;
         g_trend = -1;

         if(isLive)
            FireAlert(sym + " " + tf +
                      " | ⚡ CHoCH → Trend flipped BEARISH @ " +
                      DoubleToString(price, _Digits), confirmBar);
        }
      else if(isLL && g_trend == 0)
         g_trend = -1;
      else if(isHL && g_trend == -1)
         g_trend = 1;
      else if(isHL && g_trend == 0)
         g_trend = 1;

      // Update last pivot low
      if(g_lastPL == 0 || price != g_lastPL)
        { g_lastPL = price;  g_lastPLBar = pivBar; }

      // ── BUY Signal on every confirmed HL ─────────────────────
      if(isHL && InpShowDots)
        {
         bool withTrend = (g_trend == 1);  // HL in bull = with-trend buy
         if(withTrend)
           {
            bufWT[pivBar] = price;
            if(isLive)
               FireAlert(sym + " " + tf +
                         " | 🟢 BUY   @ " + DoubleToString(price, _Digits) +
                         "  | Trend: Bullish (With-Trend)", confirmBar);
           }
         else if(InpShowCTSig)
           {
            bufCT[pivBar] = price;
            if(isLive)
               FireAlert(sym + " " + tf +
                         " | 🟡 BUY   @ " + DoubleToString(price, _Digits) +
                         "  | Trend: Bearish (Counter-Trend)", confirmBar);
           }
        }
     }
  }

// ================================================================
// OnCalculate
// Arrays are NOT time-series (index 0 = oldest bar).
// ================================================================
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
   if(rates_total < InpSwingLeft + InpSwingRight + 1) return prev_calculated;

   // --- Full recalculation ---
   if(prev_calculated == 0)
     {
      ResetAll();
      ArrayInitialize(BufBuyWT,   0);
      ArrayInitialize(BufBuyCT,   0);
      ArrayInitialize(BufSellWT,  0);
      ArrayInitialize(BufSellCT,  0);
      ArrayInitialize(BufChochB,  0);
      ArrayInitialize(BufChochBr, 0);
     }

   // Reprocess from (prev_calculated - InpSwingRight - 1) to catch
   // pivots whose confirmation bar falls in the new range.
   int startBar = (prev_calculated == 0)
                  ? InpSwingLeft
                  : MathMax(InpSwingLeft, prev_calculated - InpSwingRight - 1);

   datetime tNow    = time[rates_total - 1];
   double   bw1     = 0.001 * InpBoxWidth;
   bool     isLive  = (prev_calculated > 0); // only fire alerts on incremental runs

   // ================================================================
   // MAIN BAR LOOP
   // ================================================================
   for(int i = startBar; i < rates_total; i++)
     {
      int pBar = i - InpSwingRight;   // actual pivot bar
      if(pBar < InpSwingLeft) continue;

      bool newPH = IsPivotHigh(high, pBar, InpSwingLeft, InpSwingRight, rates_total);
      bool newPL = IsPivotLow (low,  pBar, InpSwingLeft, InpSwingRight, rates_total);

      // ---- Process new pivot HIGH --------------------------------
      if(newPH && BufSellWT[pBar] == 0.0 && BufSellCT[pBar] == 0.0
         && BufChochB[pBar] == 0.0)
        {
         double phPrice = high[pBar];
         double boxTop  = phPrice * (1.0 + bw1);
         double boxBot  = phPrice;

         string ln = PFX + "LH_" + IntegerToString(pBar);
         string bx = PFX + "BH_" + IntegerToString(pBar);

         DrawLine(ln, phPrice, time[pBar], time[i], InpHighColor);
         DrawBox (bx, boxTop, boxBot, time[pBar], time[i], InpHighColor);
         AddLevel(phPrice, boxTop, boxBot, time[pBar], true, ln, bx);

         // Signal + structure update (passes sell buffers for highs)
         ProcessPivot(true, phPrice, pBar, i,
                      isLive && i == rates_total - 1,
                      time, BufSellWT, BufSellCT, BufChochB, BufChochBr);
        }

      // ---- Process new pivot LOW ---------------------------------
      if(newPL && BufBuyWT[pBar] == 0.0 && BufBuyCT[pBar] == 0.0
         && BufChochBr[pBar] == 0.0)
        {
         double plPrice = low[pBar];
         double boxBot2 = plPrice * (1.0 - bw1);
         double boxTop2 = plPrice;

         string ln = PFX + "LL_" + IntegerToString(pBar);
         string bx = PFX + "BL_" + IntegerToString(pBar);

         DrawLine(ln, plPrice, time[pBar], time[i], InpLowColor);
         DrawBox (bx, boxTop2, boxBot2, time[pBar], time[i], InpLowColor);
         AddLevel(plPrice, boxTop2, boxBot2, time[pBar], false, ln, bx);

         // Signal + structure update (passes buy buffers for lows)
         ProcessPivot(false, plPrice, pBar, i,
                      isLive && i == rates_total - 1,
                      time, BufBuyWT, BufBuyCT, BufChochB, BufChochBr);
        }

      // ---- Extend / fill-check on live bar only -----------------
      if(i == rates_total - 1)
        {
         int j = 0;
         while(j < g_nLv)
           {
            double lp     = g_lv[j].price;
            bool   filled = (high[i] >= lp && low[i] <= lp);
            color  col    = g_lv[j].isHigh ? InpHighColor : InpLowColor;

            if(filled && InpHideFilled)
              { RemoveLevel(j); continue; }

            if(filled && InpExtendFill)
              {
               // Stop extending – keep drawn objects frozen in place
               ObjectDelete(0, g_lv[j].lineName);
               ObjectDelete(0, g_lv[j].boxName);
               g_lv[j] = g_lv[g_nLv - 1];
               g_nLv--;
               ArrayResize(g_lv, g_nLv);
               continue;
              }

            if(!InpExtendFill) { j++; continue; }

            // Extend right edge
            DrawLine(g_lv[j].lineName, lp, g_lv[j].t1, tNow, col);
            DrawBox (g_lv[j].boxName,
                     g_lv[j].boxTop, g_lv[j].boxBot,
                     g_lv[j].t1, tNow, col);

            if(g_nLv >= MAX_OBJECTS) RemoveLevel(0);
            j++;
           }
        }
     }

   return rates_total;
  }
//+------------------------------------------------------------------+
