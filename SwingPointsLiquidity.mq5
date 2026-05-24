//+------------------------------------------------------------------+
//|                                       SwingPointsLiquidity.mq5  |
//|          Port of "Swing Points and Liquidity" by LeviathanCap.  |
//|          + Market Structure (HH / HL / LH / LL)                 |
//|          + CHoCH / MSS Detection                                 |
//|          + Push Notifications with SL / TP1 / TP2 / TP3         |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.20"
#property indicator_chart_window
#property indicator_plots 6

//--- Plot 0 : BUY  With-Trend  (HL in bull)
#property indicator_label1  "BUY - Bull"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  2

//--- Plot 1 : BUY  Counter-Trend  (HL in bear)
#property indicator_label2  "BUY - Bear (CT)"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  C'0,130,60'
#property indicator_width2  1

//--- Plot 2 : BUY  MSS retrace
#property indicator_label3  "BUY - MSS"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrDeepSkyBlue
#property indicator_width3  2

//--- Plot 3 : SELL  With-Trend  (LH in bear)
#property indicator_label4  "SELL - Bear"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrCrimson
#property indicator_width4  2

//--- Plot 4 : SELL  Counter-Trend  (LH in bull)
#property indicator_label5  "SELL - Bull (CT)"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  C'140,40,50'
#property indicator_width5  1

//--- Plot 5 : SELL  MSS retrace
#property indicator_label6  "SELL - MSS"
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
input bool   InpExtendFill   = true;             // Extend Until Filled
input bool   InpHideFilled   = false;            // Hide Filled Levels
input bool   InpShowCTSig    = true;             // Show Counter-Trend Signals

input group "=== Appearance ==="
input color  InpHighColor    = C'170,36,48';     // Swing High Colour
input color  InpLowColor     = C'102,187,106';   // Swing Low Colour
input ENUM_LINE_STYLE InpLineStyle = STYLE_DOT;  // Line Style
input int    InpLineWidth    = 1;                // Line Width
input double InpBoxWidth     = 0.7;              // Box Width % (0.1-2.0)

input group "=== Market Structure ==="
input bool   InpShowMSSLabel = true;             // Draw CHoCH label on chart
input color  InpMSSBullCol   = clrDeepSkyBlue;   // CHoCH → Bullish colour
input color  InpMSSBearCol   = clrOrangeRed;     // CHoCH → Bearish colour

input group "=== Alerts & Push ==="
input bool   InpAlerts       = true;             // Pop-up Alerts
input bool   InpPush         = true;             // Push Notifications (mobile)

// ================================================================
// BUFFERS
// ================================================================
double BufBuyBull[];   // BUY | Bull
double BufBuyCT[];     // BUY | Bear (counter-trend)
double BufBuyMSS[];    // BUY | MSS
double BufSellBear[];  // SELL | Bear
double BufSellCT[];    // SELL | Bull (counter-trend)
double BufSellMSS[];   // SELL | MSS

// ================================================================
// CONSTANTS & GLOBALS
// ================================================================
const string PFX         = "SPL_";
const int    MAX_OBJECTS = 500;
const int    MAX_HISTORY = 60;   // swing history depth for TP search

//--- Liquidity level tracking
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

//--- Swing price history (for TP calculation)
double   g_swHi[];   int g_nSH = 0;   // confirmed swing highs
double   g_swLo[];   int g_nSL = 0;   // confirmed swing lows

//--- Market-structure state
double   g_lastPH    = 0;
double   g_lastPL    = 0;
int      g_lastPHBar = -1;
int      g_lastPLBar = -1;
int      g_trend     = 0;   // 0=undef  1=bull  -1=bear

//--- MSS retrace tracking
double   g_mssLevel  = 0;
double   g_mssSL     = 0;   // SL for the MSS trade (CHoCH pivot)
bool     g_mssActive = false;
bool     g_mssBull   = false;  // true=expecting BUY retrace, false=SELL
int      g_mssBar    = -1;     // bar the MSS was set on (dedup)

//--- Alert dedup
int      g_lastAlertBar = -1;

// ================================================================
// OnInit
// ================================================================
int OnInit()
  {
   SetIndexBuffer(0, BufBuyBull,  INDICATOR_DATA);
   SetIndexBuffer(1, BufBuyCT,    INDICATOR_DATA);
   SetIndexBuffer(2, BufBuyMSS,   INDICATOR_DATA);
   SetIndexBuffer(3, BufSellBear, INDICATOR_DATA);
   SetIndexBuffer(4, BufSellCT,   INDICATOR_DATA);
   SetIndexBuffer(5, BufSellMSS,  INDICATOR_DATA);

   // ▲ up arrow for buys, ▼ down arrow for sells
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 233);
   PlotIndexSetInteger(2, PLOT_ARROW, 233);
   PlotIndexSetInteger(3, PLOT_ARROW, 234);
   PlotIndexSetInteger(4, PLOT_ARROW, 234);
   PlotIndexSetInteger(5, PLOT_ARROW, 234);

   // Shift arrows: buys below bar, sells above bar
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT,  12);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT,  12);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT,  12);
   PlotIndexSetInteger(3, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(4, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(5, PLOT_ARROW_SHIFT, -12);

   for(int p = 0; p < 6; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, 0.0);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("SP&L (%d/%d)", InpSwingLeft, InpSwingRight));

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
  }

// ================================================================
// HELPERS : pivot detection
// Index 0 = oldest bar (non-series orientation).
// ================================================================
bool IsPivotHigh(const double &h[], int pos, int L, int R, int total)
  {
   if(pos - L < 0 || pos + R >= total) return false;
   double v = h[pos];
   for(int k = 1; k <= L; k++) if(h[pos - k] >= v) return false;
   for(int k = 1; k <= R; k++) if(h[pos + k] >= v) return false;
   return true;
  }

bool IsPivotLow(const double &l[], int pos, int L, int R, int total)
  {
   if(pos - L < 0 || pos + R >= total) return false;
   double v = l[pos];
   for(int k = 1; k <= L; k++) if(l[pos - k] <= v) return false;
   for(int k = 1; k <= R; k++) if(l[pos + k] <= v) return false;
   return true;
  }

// ================================================================
// HELPERS : swing history
// ================================================================
void AddSwingHigh(double p)
  {
   if(g_nSH >= MAX_HISTORY)
     { for(int i = 0; i < g_nSH - 1; i++) g_swHi[i] = g_swHi[i + 1]; g_nSH--; }
   ArrayResize(g_swHi, g_nSH + 1);
   g_swHi[g_nSH++] = p;
  }

void AddSwingLow(double p)
  {
   if(g_nSL >= MAX_HISTORY)
     { for(int i = 0; i < g_nSL - 1; i++) g_swLo[i] = g_swLo[i + 1]; g_nSL--; }
   ArrayResize(g_swLo, g_nSL + 1);
   g_swLo[g_nSL++] = p;
  }

// ================================================================
// HELPERS : TP calculation
// BUY  TPs → 3 nearest swing HIGHS above entry, ascending price
// SELL TPs → 3 nearest swing LOWS  below entry, descending price
// ================================================================
void FindBuyTPs(double entry, double &tp1, double &tp2, double &tp3)
  {
   tp1 = tp2 = tp3 = 0.0;
   double c[]; int n = 0;
   for(int i = 0; i < g_nSH; i++)
      if(g_swHi[i] > entry) { ArrayResize(c, n + 1); c[n++] = g_swHi[i]; }
   if(n == 0) return;
   ArraySort(c);  // ascending → closest first
   if(n >= 1) tp1 = c[0];
   if(n >= 2) tp2 = c[1];
   if(n >= 3) tp3 = c[2];
  }

void FindSellTPs(double entry, double &tp1, double &tp2, double &tp3)
  {
   tp1 = tp2 = tp3 = 0.0;
   double c[]; int n = 0;
   for(int i = 0; i < g_nSL; i++)
      if(g_swLo[i] < entry) { ArrayResize(c, n + 1); c[n++] = g_swLo[i]; }
   if(n == 0) return;
   ArraySort(c);
   // Reverse → highest (closest to entry) first
   for(int i = 0, j = n - 1; i < j; i++, j--) { double t = c[i]; c[i] = c[j]; c[j] = t; }
   if(n >= 1) tp1 = c[0];
   if(n >= 2) tp2 = c[1];
   if(n >= 3) tp3 = c[2];
  }

// ================================================================
// HELPERS : notification
// ================================================================
string TFStr()
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
      default:         return "";
     }
  }

string PriceStr(double p)
  { return (p > 0.0) ? DoubleToString(p, _Digits) : "N/A"; }

// Fire the alert + push for a signal
void FireSignal(const string &dir,      // "BUY" or "SELL"
                const string &label,    // "Bull" / "Bear" / "MSS"
                double        sigPrice, // price at signal bar
                double        sl,
                double        tp1,
                double        tp2,
                double        tp3,
                int           confirmBar,
                bool          isLive)
  {
   if(!isLive) return;
   if(!InpAlerts && !InpPush) return;
   if(g_lastAlertBar == confirmBar) return;   // one alert per bar
   g_lastAlertBar = confirmBar;

   string msg = dir + " (" + _Symbol + " " + TFStr() +
                " " + DoubleToString(sigPrice, _Digits) + ")" +
                " | " + label +
                " | SL: "  + PriceStr(sl)  +
                " | TP1: " + PriceStr(tp1) +
                " | TP2: " + PriceStr(tp2) +
                " | TP3: " + PriceStr(tp3);

   if(InpAlerts) Alert(msg);
   if(InpPush)   SendNotification(msg);
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
                        (int)((col & 0xFF) * 0.22));
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
   if(!InpShowMSSLabel || ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT,       txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     above ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   8);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

// ================================================================
// HELPERS : level array
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
// HELPERS : reset
// ================================================================
void ResetAll()
  {
   ObjectsDeleteAll(0, PFX);
   ArrayResize(g_lv,   0); g_nLv = 0;
   ArrayResize(g_swHi, 0); g_nSH = 0;
   ArrayResize(g_swLo, 0); g_nSL = 0;
   g_lastPH = g_lastPL = 0;
   g_lastPHBar = g_lastPLBar = -1;
   g_trend     = 0;
   g_mssLevel  = g_mssSL = 0;
   g_mssActive = false;
   g_mssBar    = -1;
   g_lastAlertBar = -1;
  }

// ================================================================
// OnCalculate
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

   if(prev_calculated == 0)
     {
      ResetAll();
      ArrayInitialize(BufBuyBull,  0);
      ArrayInitialize(BufBuyCT,    0);
      ArrayInitialize(BufBuyMSS,   0);
      ArrayInitialize(BufSellBear, 0);
      ArrayInitialize(BufSellCT,   0);
      ArrayInitialize(BufSellMSS,  0);
     }

   int startBar = (prev_calculated == 0)
                  ? InpSwingLeft
                  : MathMax(InpSwingLeft, prev_calculated - InpSwingRight - 1);

   datetime tNow   = time[rates_total - 1];
   double   bw1    = 0.001 * InpBoxWidth;
   bool     isLive = (prev_calculated > 0);   // suppress alerts on full recalc

   // ================================================================
   // MAIN BAR LOOP  (chronological, oldest → newest)
   // ================================================================
   for(int i = startBar; i < rates_total; i++)
     {
      int pBar = i - InpSwingRight;
      if(pBar < InpSwingLeft) continue;

      bool newPH = IsPivotHigh(high, pBar, InpSwingLeft, InpSwingRight, rates_total);
      bool newPL = IsPivotLow (low,  pBar, InpSwingLeft, InpSwingRight, rates_total);

      // ── NEW PIVOT HIGH ──────────────────────────────────────────
      if(newPH && BufSellBear[pBar] == 0.0 && BufSellCT[pBar] == 0.0)
        {
         double ph = high[pBar];

         // Draw liquidity line + box
         string ln = PFX + "LH_" + IntegerToString(pBar);
         string bx = PFX + "BH_" + IntegerToString(pBar);
         DrawLine(ln, ph,  time[pBar], time[i], InpHighColor);
         DrawBox (bx, ph * (1.0 + bw1), ph, time[pBar], time[i], InpHighColor);
         AddLevel(ph, ph * (1.0 + bw1), ph, time[pBar], true, ln, bx);

         // Classify: HH or LH
         bool isHH = (g_lastPH == 0 || ph > g_lastPH);

         if(isHH && g_trend == -1)
           {
            // ─── CHoCH: bear → bull ───────────────────────────────
            DrawChochLabel(PFX + "CHoCH_" + IntegerToString(pBar),
                           "CHoCH", time[pBar], ph, InpMSSBullCol, false);
            // Save MSS: SELL retrace when price returns to this LH level
            // (the LH that got broken by the HH means we now track
            //  price returning to that old LH for a BUY | MSS trade)
            g_mssLevel  = g_lastPH;   // the old LH (resistance that was broken)
            g_mssSL     = ph;         // SL = the HH that confirmed the CHoCH
            g_mssActive = true;
            g_mssBull   = true;       // looking for BUY retrace to old LH
            g_mssBar    = pBar;
            g_trend     = 1;
           }
         else if(isHH)
            g_trend = (g_trend == 0) ? 1 : g_trend;
         else
           {
            // LH  → SELL signal
            if(g_trend == 1) g_trend = -1;
            else if(g_trend == 0) g_trend = -1;

            double tp1, tp2, tp3;
            FindSellTPs(ph, tp1, tp2, tp3);
            double sl = ph;   // SL at the swing that formed the signal

            bool withTrend = (g_trend == -1);
            if(withTrend)
              {
               BufSellBear[pBar] = ph;
               FireSignal("SELL", "Bear", ph, sl, tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1);
              }
            else if(InpShowCTSig)
              {
               BufSellCT[pBar] = ph;
               FireSignal("SELL", "Bull", ph, sl, tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1);
              }
           }

         // Always add to swing-high history (used for BUY TPs later)
         AddSwingHigh(ph);
         g_lastPH = ph;  g_lastPHBar = pBar;
        }

      // ── NEW PIVOT LOW ───────────────────────────────────────────
      if(newPL && BufBuyBull[pBar] == 0.0 && BufBuyCT[pBar] == 0.0)
        {
         double pl = low[pBar];

         string ln = PFX + "LL_" + IntegerToString(pBar);
         string bx = PFX + "BL_" + IntegerToString(pBar);
         DrawLine(ln, pl,  time[pBar], time[i], InpLowColor);
         DrawBox (bx, pl, pl * (1.0 - bw1), time[pBar], time[i], InpLowColor);
         AddLevel(pl, pl, pl * (1.0 - bw1), time[pBar], false, ln, bx);

         // Classify: LL or HL
         bool isLL = (g_lastPL == 0 || pl < g_lastPL);

         if(isLL && g_trend == 1)
           {
            // ─── CHoCH: bull → bear ───────────────────────────────
            DrawChochLabel(PFX + "CHoCH_" + IntegerToString(pBar),
                           "CHoCH", time[pBar], pl, InpMSSBearCol, true);
            // MSS: BUY retrace when price returns to old HL (now resistance)
            g_mssLevel  = g_lastPL;   // old HL that was broken
            g_mssSL     = pl;         // SL = the LL that confirmed the CHoCH
            g_mssActive = true;
            g_mssBull   = false;      // looking for SELL retrace to old HL
            g_mssBar    = pBar;
            g_trend     = -1;
           }
         else if(isLL)
            g_trend = (g_trend == 0) ? -1 : g_trend;
         else
           {
            // HL → BUY signal
            if(g_trend == -1) g_trend = 1;
            else if(g_trend == 0) g_trend = 1;

            double tp1, tp2, tp3;
            FindBuyTPs(pl, tp1, tp2, tp3);
            double sl = pl;   // SL at the swing that formed the signal

            bool withTrend = (g_trend == 1);
            if(withTrend)
              {
               BufBuyBull[pBar] = pl;
               FireSignal("BUY", "Bull", pl, sl, tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1);
              }
            else if(InpShowCTSig)
              {
               BufBuyCT[pBar] = pl;
               FireSignal("BUY", "Bear", pl, sl, tp1, tp2, tp3, i,
                          isLive && i == rates_total - 1);
              }
           }

         AddSwingLow(pl);
         g_lastPL = pl;  g_lastPLBar = pBar;
        }

      // ── MSS RETRACE CHECK (every bar) ───────────────────────────
      if(g_mssActive && g_mssLevel > 0)
        {
         bool fired = false;

         if(g_mssBull && low[i] <= g_mssLevel && BufBuyMSS[i] == 0.0)
           {
            // Price retraced DOWN to old LH (broken resistance → support)
            // → BUY | MSS
            BufBuyMSS[i] = low[i];
            double tp1, tp2, tp3;
            FindBuyTPs(g_mssLevel, tp1, tp2, tp3);
            FireSignal("BUY", "MSS", g_mssLevel, g_mssSL,
                       tp1, tp2, tp3, i,
                       isLive && i == rates_total - 1);
            fired = true;
           }

         if(!g_mssBull && high[i] >= g_mssLevel && BufSellMSS[i] == 0.0)
           {
            // Price retraced UP to old HL (broken support → resistance)
            // → SELL | MSS
            BufSellMSS[i] = high[i];
            double tp1, tp2, tp3;
            FindSellTPs(g_mssLevel, tp1, tp2, tp3);
            FireSignal("SELL", "MSS", g_mssLevel, g_mssSL,
                       tp1, tp2, tp3, i,
                       isLive && i == rates_total - 1);
            fired = true;
           }

         if(fired) g_mssActive = false;   // one MSS signal per CHoCH
        }

      // ── EXTEND LEVELS (live bar only) ───────────────────────────
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
               ObjectDelete(0, g_lv[j].lineName);
               ObjectDelete(0, g_lv[j].boxName);
               g_lv[j] = g_lv[g_nLv - 1];
               g_nLv--;
               ArrayResize(g_lv, g_nLv);
               continue;
              }

            if(!InpExtendFill) { j++; continue; }

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
