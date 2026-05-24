//+------------------------------------------------------------------+
//|                                       SwingPointsLiquidity.mq5  |
//|          Port of "Swing Points and Liquidity" by LeviathanCap.  |
//|          + Market Structure (HH/HL/LH/LL)                       |
//|          + CHoCH / MSS Detection                                 |
//|          + Buy / Sell Signal Generation                          |
//+------------------------------------------------------------------+
#property copyright "bidiisStrategy"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 4

//--- Plot 0 : Pivot-high dots (circles)
#property indicator_label1  "Pivot High"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrCrimson
#property indicator_width1  1

//--- Plot 1 : Pivot-low dots
#property indicator_label2  "Pivot Low"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLimeGreen
#property indicator_width2  1

//--- Plot 2 : Buy arrow
#property indicator_label3  "Buy"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrDeepSkyBlue
#property indicator_width3  2

//--- Plot 3 : Sell arrow
#property indicator_label4  "Sell"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrOrangeRed
#property indicator_width4  2

// ================================================================
// INPUTS
// ================================================================
input group "=== Swing Detection ==="
input int    InpSwingRight   = 10;               // Bars Right
input int    InpSwingLeft    = 15;               // Bars Left

input group "=== Display ==="
input bool   InpShowBoxes    = true;             // Show Liquidity Boxes
input bool   InpShowLines    = true;             // Show Level Lines
input bool   InpShowDots     = true;             // Show Pivot Dots
input bool   InpExtendFill   = true;             // Extend Until Filled
input bool   InpHideFilled   = false;            // Hide Filled Levels

input group "=== Appearance ==="
input color  InpHighColor    = C'170,36,48';     // Swing High Colour
input color  InpLowColor     = C'102,187,106';   // Swing Low Colour
input ENUM_LINE_STYLE InpLineStyle = STYLE_DOT;  // Line Style
input int    InpLineWidth    = 1;                // Line Width
input double InpBoxWidth     = 0.7;              // Box Width % (0.1-2.0)

input group "=== Market Structure & Signals ==="
input bool   InpShowMSS      = true;             // Show CHoCH / MSS Labels
input bool   InpShowSignals  = true;             // Show Buy / Sell Arrows
input color  InpMSSBullCol   = clrDeepSkyBlue;   // CHoCH → Bullish colour
input color  InpMSSBearCol   = clrOrangeRed;     // CHoCH → Bearish colour

// ================================================================
// BUFFERS
// ================================================================
double BufPH[];    // pivot-high dot values
double BufPL[];    // pivot-low  dot values
double BufBuy[];   // buy  signal values
double BufSell[];  // sell signal values

// ================================================================
// CONSTANTS / GLOBALS
// ================================================================
const string PFX         = "SPL_";   // object name prefix
const int    MAX_OBJECTS = 500;      // mirror Pine max_boxes_count

// ----------------------------------------------------------------
// Level tracking (mirrors Pine's levelBoxes / levelLines arrays)
// ----------------------------------------------------------------
struct SLevel
  {
   double   price;
   double   boxTop;
   double   boxBot;
   datetime t1;       // time of pivot bar
   bool     isHigh;
   bool     filled;
   string   lineName;
   string   boxName;
  };

SLevel   g_lv[];
int      g_nLv = 0;

// ----------------------------------------------------------------
// Market-structure state (persistent across bars)
// ----------------------------------------------------------------
double   g_lastPH    = 0;
double   g_lastPL    = 0;
int      g_lastPHBar = -1;
int      g_lastPLBar = -1;
int      g_trend     = 0;    // 0=undefined  1=bull  -1=bear
double   g_mssLevel  = 0;
bool     g_mssActive = false;
bool     g_mssBull   = false; // true=looking for buy retrace  false=sell

// ================================================================
// OnInit
// ================================================================
int OnInit()
  {
   SetIndexBuffer(0, BufPH,   INDICATOR_DATA);
   SetIndexBuffer(1, BufPL,   INDICATOR_DATA);
   SetIndexBuffer(2, BufBuy,  INDICATOR_DATA);
   SetIndexBuffer(3, BufSell, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_ARROW, 159);  // ● small circle
   PlotIndexSetInteger(1, PLOT_ARROW, 159);
   PlotIndexSetInteger(2, PLOT_ARROW, 233);  // ▲ up arrow
   PlotIndexSetInteger(3, PLOT_ARROW, 234);  // ▼ down arrow

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);

   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT,  10);  // buy  arrow below bar
   PlotIndexSetInteger(3, PLOT_ARROW_SHIFT, -10);  // sell arrow above bar

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
// HELPER : pivot detection
// Arrays are NOT time-series (index 0 = oldest bar)
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
// HELPER : object drawing
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
   // Dim colour to ~20 % for a semi-transparent feel behind candles
   color dim = (color)(((int)(((col >> 16) & 0xFF) * 0.25) << 16) |
                       ((int)(((col >>  8) & 0xFF) * 0.25) <<  8) |
                        (int)((col         & 0xFF) * 0.25));
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, top, t2, bot);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      dim);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,    dim);
      ObjectSetInteger(0, name, OBJPROP_FILL,       true);
      ObjectSetInteger(0, name, OBJPROP_BACK,       true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 0, top);
      ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, name, OBJPROP_PRICE, 1, bot);
     }
  }

// Draw a short text label (CHoCH / MSS)
void DrawMSSLabel(const string &name, const string &txt,
                  datetime t, double price, color col, bool isUp)
  {
   if(!InpShowMSS) return;
   if(ObjectFind(0, name) >= 0) return;  // draw once
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    isUp ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  8);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
  }

// Draw (or refresh) the active MSS level line
void DrawMSSLine(double price, datetime t1, datetime t2, color col)
  {
   string n = PFX + "MSS_LVL";
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, n, OBJPROP_COLOR,     col);
      ObjectSetInteger(0, n, OBJPROP_STYLE,     STYLE_DASH);
      ObjectSetInteger(0, n, OBJPROP_WIDTH,     2);
      ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,    true);
     }
   else
     {
      ObjectSetInteger(0, n, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, n, OBJPROP_PRICE, 0, price);
      ObjectSetDouble (0, n, OBJPROP_PRICE, 1, price);
     }
  }

// ================================================================
// HELPER : level array management
// ================================================================
void AddLevel(double price, double boxTop, double boxBot,
              datetime t1, bool isHigh,
              const string &lnName, const string &bxName)
  {
   ArrayResize(g_lv, g_nLv + 1);
   g_lv[g_nLv].price    = price;
   g_lv[g_nLv].boxTop   = boxTop;
   g_lv[g_nLv].boxBot   = boxBot;
   g_lv[g_nLv].t1       = t1;
   g_lv[g_nLv].isHigh   = isHigh;
   g_lv[g_nLv].filled   = false;
   g_lv[g_nLv].lineName = lnName;
   g_lv[g_nLv].boxName  = bxName;
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
// HELPER : reset everything for a full recalculation
// ================================================================
void ResetAll()
  {
   ObjectsDeleteAll(0, PFX);
   ArrayResize(g_lv, 0);
   g_nLv      = 0;
   g_lastPH   = 0;  g_lastPHBar = -1;
   g_lastPL   = 0;  g_lastPLBar = -1;
   g_trend    = 0;
   g_mssLevel = 0;  g_mssActive = false;  g_mssBull = false;
  }

// ================================================================
// MARKET-STRUCTURE LOGIC
// Called once per confirmed pivot.
// pivBar : absolute bar index (0=oldest) of the pivot
// isHigh : true = pivot high, false = pivot low
// price  : high[pivBar] or low[pivBar]
// time[] : the main time array
// ================================================================
void UpdateStructure(int pivBar, bool isHigh, double price,
                     const datetime &time[], int total)
  {
   if(isHigh)
     {
      if(g_lastPH == 0) { g_lastPH = price; g_lastPHBar = pivBar; return; }

      if(price > g_lastPH)   // Higher High
        {
         if(g_trend == -1)   // Was bearish → CHoCH bullish
           {
            string n = PFX + "CHoCH_" + IntegerToString(pivBar);
            DrawMSSLabel(n, "CHoCH", time[pivBar], price,
                         InpMSSBullCol, false);
            g_mssLevel  = g_lastPH;   // the LH that was exceeded
            g_mssActive = true;
            g_mssBull   = true;       // look for buy retrace
           }
         g_trend = 1;
        }
      else                    // Lower High
        {
         g_trend = (g_trend == 0) ? -1 : g_trend; // keep existing if defined
         if(g_trend == 1) g_trend = -1;
        }
      g_lastPH = price;  g_lastPHBar = pivBar;
     }
   else  // pivot low
     {
      if(g_lastPL == 0) { g_lastPL = price; g_lastPLBar = pivBar; return; }

      if(price < g_lastPL)   // Lower Low
        {
         if(g_trend == 1)    // Was bullish → CHoCH bearish
           {
            string n = PFX + "CHoCH_" + IntegerToString(pivBar);
            DrawMSSLabel(n, "CHoCH", time[pivBar], price,
                         InpMSSBearCol, true);
            g_mssLevel  = g_lastPL;   // the HL that was broken
            g_mssActive = true;
            g_mssBull   = false;      // look for sell retrace
           }
         g_trend = -1;
        }
      else                    // Higher Low
        {
         g_trend = (g_trend == 0) ? 1 : g_trend;
         if(g_trend == -1) g_trend = 1;
        }
      g_lastPL = price;  g_lastPLBar = pivBar;
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
   // --- Full recalculation ---
   if(prev_calculated == 0)
     {
      ResetAll();
      ArrayInitialize(BufPH,   0);
      ArrayInitialize(BufPL,   0);
      ArrayInitialize(BufBuy,  0);
      ArrayInitialize(BufSell, 0);
     }

   // --- How far back to (re)start processing ---
   // Pivots confirmed InpSwingRight bars after the actual pivot,
   // so we must look back InpSwingRight extra bars on incremental runs.
   int startBar = (prev_calculated == 0)
                  ? InpSwingLeft
                  : MathMax(InpSwingLeft, prev_calculated - InpSwingRight - 1);

   datetime tNow = time[rates_total - 1];  // latest bar time (for extending objects)

   double bw1 = 0.001 * InpBoxWidth;  // mirrors Pine's boxWid1

   // ================================================================
   // MAIN BAR LOOP
   // ================================================================
   for(int i = startBar; i < rates_total; i++)
     {
      // ---- Pivot check: the actual pivot bar is i - InpSwingRight ----
      int pBar = i - InpSwingRight;
      if(pBar < InpSwingLeft) continue;

      bool newPH = IsPivotHigh(high, pBar, InpSwingLeft, InpSwingRight, rates_total);
      bool newPL = IsPivotLow (low,  pBar, InpSwingLeft, InpSwingRight, rates_total);

      // --- Create level objects for new pivots -----------------------
      if(newPH && BufPH[pBar] == 0.0)
        {
         double phPrice = high[pBar];
         double boxTop  = phPrice * (1.0 + bw1);
         double boxBot  = phPrice;  // TYPE 1: bot = pivot price

         string lnName  = PFX + "LH_" + IntegerToString(pBar);
         string bxName  = PFX + "BH_" + IntegerToString(pBar);

         DrawLine(lnName, phPrice,   time[pBar], time[i], InpHighColor);
         DrawBox (bxName, boxTop, boxBot, time[pBar], time[i], InpHighColor);

         AddLevel(phPrice, boxTop, boxBot, time[pBar], true, lnName, bxName);

         // Dot on the pivot bar
         if(InpShowDots) BufPH[pBar] = phPrice;

         // Market structure update
         UpdateStructure(pBar, true, phPrice, time, rates_total);
        }

      if(newPL && BufPL[pBar] == 0.0)
        {
         double plPrice = low[pBar];
         double boxBot2 = plPrice * (1.0 - bw1);
         double boxTop2 = plPrice;  // TYPE 1: top = pivot price

         string lnName  = PFX + "LL_" + IntegerToString(pBar);
         string bxName  = PFX + "BL_" + IntegerToString(pBar);

         DrawLine(lnName, plPrice,   time[pBar], time[i], InpLowColor);
         DrawBox (bxName, boxTop2, boxBot2, time[pBar], time[i], InpLowColor);

         AddLevel(plPrice, boxTop2, boxBot2, time[pBar], false, lnName, bxName);

         if(InpShowDots) BufPL[pBar] = plPrice;

         UpdateStructure(pBar, false, plPrice, time, rates_total);
        }

      // --- Update all active levels (extend right edge) --------------
      // Only on the current bar (i == rates_total-1) to avoid O(n²) on full recalc
      if(i == rates_total - 1)
        {
         int j = 0;
         while(j < g_nLv)
           {
            double lvPrice = g_lv[j].price;
            bool   filled  = (high[i] >= lvPrice && low[i] <= lvPrice);

            if(filled && InpHideFilled)
              {
               RemoveLevel(j);   // deletes objects and removes from array
               continue;
              }

            if(filled && InpExtendFill)
              {
               // Stop extending – remove tracking but keep drawn objects as-is
               ObjectDelete(0, g_lv[j].lineName);
               ObjectDelete(0, g_lv[j].boxName);
               g_lv[j] = g_lv[g_nLv - 1];
               g_nLv--;
               ArrayResize(g_lv, g_nLv);
               continue;
              }

            if(!InpExtendFill)
              {
               // Don't extend past confirmation bar – already drawn to time[i]
               // Nothing to update; just leave as-is
               j++;
               continue;
              }

            // Extend right edge to current bar
            color col = g_lv[j].isHigh ? InpHighColor : InpLowColor;
            DrawLine(g_lv[j].lineName, lvPrice,
                     g_lv[j].t1, tNow, col);
            DrawBox (g_lv[j].boxName,
                     g_lv[j].boxTop, g_lv[j].boxBot,
                     g_lv[j].t1, tNow, col);

            // Cap object count (mirrors Pine's 500 limit)
            if(g_nLv >= MAX_OBJECTS) RemoveLevel(0);

            j++;
           }
        }

      // --- MSS level line & signal generation ------------------------
      if(g_mssActive && i == rates_total - 1)
        {
         color mssCol = g_mssBull ? InpMSSBullCol : InpMSSBearCol;

         // Find t1 for the MSS level line (use creation bar)
         datetime mssT1 = (g_mssBull)
                          ? time[g_lastPHBar < 0 ? 0 : g_lastPHBar]
                          : time[g_lastPLBar < 0 ? 0 : g_lastPLBar];
         DrawMSSLine(g_mssLevel, mssT1, tNow, mssCol);
        }

      // --- Signal: price returns to MSS level ------------------------
      if(InpShowSignals && g_mssActive)
        {
         if(g_mssBull && low[i] <= g_mssLevel && BufBuy[i] == 0.0)
           {
            BufBuy[i]   = low[i];
            g_mssActive = false;  // one signal per CHoCH
            ObjectDelete(0, PFX + "MSS_LVL");
           }
         if(!g_mssBull && high[i] >= g_mssLevel && BufSell[i] == 0.0)
           {
            BufSell[i]  = high[i];
            g_mssActive = false;
            ObjectDelete(0, PFX + "MSS_LVL");
           }
        }
     }  // end main bar loop

   return rates_total;
  }
//+------------------------------------------------------------------+
