//+------------------------------------------------------------------+
//|                                              MarkovChainEA.mq5   |
//|  Строит "цепь Маркова" (Renko-подобную сетку по Bid с шагом      |
//|  N пипсов) из потока тиков и торгует по заданным паттернам       |
//|  звеньев U(Up)/D(Down).                                          |
//|                                                                   |
//|  Логика паттерна: "UUD" -> хвост цепи должен быть "UU" (триггер),|
//|  тогда открывается сделка в направлении последнего символа "D"   |
//|  (т.е. предсказывается/торгуется это движение).                 |
//+------------------------------------------------------------------+
#property strict
#property copyright "MarkovChainEA"
#property version   "1.00"

#include <Trade/Trade.mqh>

//====================== ВХОДНЫЕ ПАРАМЕТРЫ ============================
input group "=== Настройки цепи (Renko-подобная сетка) ==="
input int    InpChainStepPips   = 10;       // Шаг звена цепи, в пипсах
input int    InpMaxChainStore   = 1000;     // Макс. хранимых звеньев (буфер истории)

input group "=== Настройки торговли ==="
input int    InpStopLossPips    = 20;       // Stop Loss, в пипсах
input double InpRiskReward      = 2.0;      // Соотношение риск:прибыль (TP = SL * RR)
input double InpRiskPercent     = 1.0;      // Риск на сделку, % от эквити
input int    InpMagic           = 20250722; // Magic number
input string InpTradeComment    = "MarkovChainEA";

input group "=== Визуализация ==="
input bool   InpDrawChain       = true;     // Рисовать цепь на графике
input int    InpMaxDrawObjects  = 300;      // Макс. хранимых на графике отрезков цепи
input bool   InpShowLabel       = true;     // Показывать текстовую метку цепи
input int    InpLabelChainLen   = 40;       // Сколько последних звеньев показывать в метке

input group "=== CSV лог звеньев цепи ==="
input bool   InpCsvEnable       = true;              // Писать звенья цепи в CSV
input string InpCsvFileName     = "MarkovChains_Links.csv"; // Имя CSV файла
input bool   InpCsvCommon       = false;             // Писать в общую папку терминала (MQL5/Files/Common)
input string InpCsvDelimiter    = ";";               // Разделитель полей CSV

input group "=== Ограничения по позициям ==="
input bool   InpOneTradePerPattern = true;  // Не более 1 позиции на паттерн одновременно

//====================== СПИСОК ПАТТЕРНОВ ==============================
// ВАЖНО: последний символ паттерна - это направление, в котором
// открывается сделка (U -> Buy, D -> Sell). Все символы ДО последнего -
// это "триггер": хвост цепи (последние L-1 звеньев) должен точно
// совпасть с этой частью, чтобы паттерн сработал.
//
// Пример: "UUD" -> если последние 2 завершённых звена цепи это U,U,
// то открывается SELL (ожидается/торгуется разворот вниз).
//
// Добавляйте сюда сколько угодно паттернов (50+, разной длины).
string PatternList[] =
{
   "UDUDUDUDUD",
   "DUDUDUDUDU",
   "UDUDUDUDU",
   "DUDUDUDUD",
   "UDUDUDUD",
   "DUDUDUDU",
   "UDUDUDU",
   "DUDUDUD"
   // ... - добавляйте свои паттерны здесь
};

//====================== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ =========================
CTrade   trade;

double   g_pipSize;      // размер 1 пипса в цене (с учётом 3/5 знаков)
double   g_stepPrice;    // размер шага цепи в цене
bool     g_chainInit   = false;
double   g_anchorPrice;  // текущая опорная цена (последний зафиксированный уровень)

int      ChainCount    = 0;
int      ChainDir[];     // +1 = Up, -1 = Down
double   ChainPrice[];   // цена уровня каждого звена
datetime ChainTime[];    // время фиксации звена

int      g_drawCounter = 0;

int      g_csvHandle  = INVALID_HANDLE; // хэндл CSV файла звеньев цепи
long     g_linkSeq    = 0;              // сквозной порядковый номер звена (не сбрасывается при обрезке буфера)

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Для 3/5-значных котировок 1 пипс = 10 пунктов, иначе 1 пипс = 1 пункт
   g_pipSize = (digits == 3 || digits == 5) ? point * 10.0 : point;
   g_stepPrice = InpChainStepPips * g_pipSize;

   ArrayResize(ChainDir,   InpMaxChainStore);
   ArrayResize(ChainPrice, InpMaxChainStore);
   ArrayResize(ChainTime,  InpMaxChainStore);
   ChainCount  = 0;
   g_chainInit = false;
   g_linkSeq   = 0;

   if(InpCsvEnable)
      OpenCsvFile();

   PrintFormat("MarkovChainEA init: digits=%d, pipSize=%.*f, stepPrice=%.*f, patterns=%d",
               digits, digits, g_pipSize, digits, g_stepPrice, ArraySize(PatternList));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Открытие (или создание) CSV файла для лога звеньев цепи            |
//+------------------------------------------------------------------+
void OpenCsvFile()
{
   int commonFlag = InpCsvCommon ? FILE_COMMON : 0;

   // Проверяем, существует ли уже файл - если да, дописываем в конец,
   // если нет - создаём и пишем заголовок.
   bool exists = FileIsExist(InpCsvFileName, commonFlag);

   int flags = FILE_CSV | FILE_ANSI | commonFlag | (exists ? FILE_READ | FILE_WRITE : FILE_WRITE);
   g_csvHandle = FileOpen(InpCsvFileName, flags, InpCsvDelimiter);

   if(g_csvHandle == INVALID_HANDLE)
   {
      PrintFormat("MarkovChainEA: не удалось открыть CSV файл '%s', код ошибки %d", InpCsvFileName, GetLastError());
      return;
   }

   if(exists)
      FileSeek(g_csvHandle, 0, SEEK_END);
   else
      FileWrite(g_csvHandle,
                "Номер", "Направление",
                "ВремяНачала", "ВремяЗавершения",
                "ЦенаНачала", "ЦенаЗавершения",
                "ДельтаЦены", "ДельтаВремениСек");
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(InpDrawChain)
      ObjectsDeleteAll(0, "MC_");
   Comment("");

   if(g_csvHandle != INVALID_HANDLE)
   {
      FileClose(g_csvHandle);
      g_csvHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!g_chainInit)
   {
      g_anchorPrice = bid;
      g_chainInit   = true;
      return;
   }

   // Шагаем по цепи вперёд, при необходимости - несколько звеньев за раз
   // (если цена ушла скачком более чем на 1 шаг сетки)
   while(MathAbs(bid - g_anchorPrice) >= g_stepPrice)
   {
      int dir = (bid > g_anchorPrice) ? 1 : -1;
      double newAnchor = g_anchorPrice + dir * g_stepPrice;
      AddChainLink(dir, newAnchor);
      g_anchorPrice = newAnchor;
   }
}

//+------------------------------------------------------------------+
//| Добавление нового звена в цепь                                    |
//+------------------------------------------------------------------+
void AddChainLink(int dir, double priceLevel)
{
   double   fromPrice = (ChainCount > 0) ? ChainPrice[ChainCount - 1] : g_anchorPrice;
   datetime fromTime   = (ChainCount > 0) ? ChainTime[ChainCount - 1]  : TimeCurrent() - PeriodSeconds();
   datetime t = TimeCurrent();

   if(ChainCount >= InpMaxChainStore)
   {
      // сдвигаем буфер влево, отбрасывая самое старое звено
      for(int i = 1; i < InpMaxChainStore; i++)
      {
         ChainDir[i-1]   = ChainDir[i];
         ChainPrice[i-1] = ChainPrice[i];
         ChainTime[i-1]  = ChainTime[i];
      }
      ChainCount = InpMaxChainStore - 1;
   }

   ChainDir[ChainCount]   = dir;
   ChainPrice[ChainCount] = priceLevel;
   ChainTime[ChainCount]  = t;
   ChainCount++;
   g_linkSeq++;

   if(InpDrawChain)
      DrawLink(dir, fromPrice, priceLevel, t);

   if(InpShowLabel)
      UpdateLabel();

   if(InpCsvEnable)
      WriteChainLinkCsv(g_linkSeq, dir, fromTime, t, fromPrice, priceLevel);

   CheckPatterns();
}

//+------------------------------------------------------------------+
//| Запись одного завершённого звена цепи в CSV файл                  |
//+------------------------------------------------------------------+
void WriteChainLinkCsv(long seq, int dir, datetime fromTime, datetime toTime, double fromPrice, double toPrice)
{
   if(g_csvHandle == INVALID_HANDLE)
      return;

   string   direction  = (dir == 1) ? "up" : "down";
   double   priceDelta = MathAbs(toPrice - fromPrice);
   long     timeDelta  = (long)(toTime - fromTime);
   int      digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   FileWrite(g_csvHandle,
             seq,
             direction,
             TimeToString(fromTime, TIME_DATE | TIME_SECONDS),
             TimeToString(toTime,   TIME_DATE | TIME_SECONDS),
             DoubleToString(fromPrice, digits),
             DoubleToString(toPrice,   digits),
             DoubleToString(priceDelta, digits),
             timeDelta);

   FileFlush(g_csvHandle);
}

//+------------------------------------------------------------------+
//| Строка из последних n направлений цепи (U/D)                      |
//+------------------------------------------------------------------+
string ChainTailString(int n)
{
   string s = "";
   if(n > ChainCount) n = ChainCount;
   for(int i = ChainCount - n; i < ChainCount; i++)
      s += (ChainDir[i] == 1) ? "U" : "D";
   return s;
}

//+------------------------------------------------------------------+
//| Проверка всех паттернов из списка на хвосте цепи                  |
//+------------------------------------------------------------------+
void CheckPatterns()
{
   int total = ArraySize(PatternList);
   for(int p = 0; p < total; p++)
   {
      string pattern = PatternList[p];
      int L = StringLen(pattern);
      if(L < 2) continue;               // паттерн должен содержать триггер + направление
      if(ChainCount < L - 1) continue;   // недостаточно звеньев для проверки триггера

      string trigger   = StringSubstr(pattern, 0, L - 1);
      string predicted = StringSubstr(pattern, L - 1, 1);
      string tail      = ChainTailString(L - 1);

      if(tail == trigger)
      {
         if(InpOneTradePerPattern && HasOpenPositionForPattern(pattern))
            continue; // по этому паттерну уже есть открытая позиция - пропускаем

         ENUM_ORDER_TYPE type = (predicted == "U") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         OpenTrade(type, pattern);
      }
   }
}

//+------------------------------------------------------------------+
//| Есть ли уже открытая позиция (этим EA, по этому символу) с          |
//| данным паттерном в комментарии?                                    |
//+------------------------------------------------------------------+
bool HasOpenPositionForPattern(string patternName)
{
   string tag = "[" + patternName + "]";
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)  continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, tag) >= 0)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Расчёт лота по проценту риска от эквити                           |
//+------------------------------------------------------------------+
double CalcLots(double slPips)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double valuePerPip = (g_pipSize / tickSize) * tickValue;
   double riskMoney   = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double lossAmount  = slPips * valuePerPip;

   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lossAmount <= 0) return minVol;

   double lots = riskMoney / lossAmount;

   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maxVol   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / stepVol) * stepVol;
   if(lots < minVol) lots = minVol;
   if(lots > maxVol) lots = maxVol;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Открытие сделки в направлении type, по паттерну patternName        |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, string patternName)
{
   double lots = CalcLots(InpStopLossPips);
   double price, sl, tp;
   string comment = InpTradeComment + " [" + patternName + "]";

   if(type == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - InpStopLossPips * g_pipSize;
      tp = price + InpStopLossPips * g_pipSize * InpRiskReward;
      if(!trade.Buy(lots, _Symbol, price, sl, tp, comment))
         PrintFormat("Buy failed [%s]: %d - %s", patternName, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + InpStopLossPips * g_pipSize;
      tp = price - InpStopLossPips * g_pipSize * InpRiskReward;
      if(!trade.Sell(lots, _Symbol, price, sl, tp, comment))
         PrintFormat("Sell failed [%s]: %d - %s", patternName, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Отрисовка одного звена цепи (тренд-линия)                         |
//+------------------------------------------------------------------+
void DrawLink(int dir, double fromPrice, double toPrice, datetime t)
{
   g_drawCounter++;
   string name = "MC_L_" + IntegerToString(g_drawCounter);
   datetime tPrev = (ChainCount >= 2) ? ChainTime[ChainCount - 2] : t - PeriodSeconds();

   ObjectCreate(0, name, OBJ_TREND, 0, tPrev, fromPrice, t, toPrice);
   ObjectSetInteger(0, name, OBJPROP_COLOR, dir == 1 ? clrDodgerBlue : clrOrangeRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   // чистим слишком старые отрезки, чтобы не засорять график
   if(g_drawCounter > InpMaxDrawObjects)
   {
      string oldName = "MC_L_" + IntegerToString(g_drawCounter - InpMaxDrawObjects);
      ObjectDelete(0, oldName);
   }
}

//+------------------------------------------------------------------+
//| Текстовая метка с последними звеньями цепи                        |
//+------------------------------------------------------------------+
void UpdateLabel()
{
   string label = "MC_LabelText";
   string txt = "Markov Chain (last " + IntegerToString(InpLabelChainLen) + "): "
              + ChainTailString(InpLabelChainLen)
              + "   [Total links: " + IntegerToString(ChainCount) + "]";

   if(ObjectFind(0, label) < 0)
   {
      ObjectCreate(0, label, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, label, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, label, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, label, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, label, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, label, OBJPROP_FONTSIZE, 10);
   }
   ObjectSetString(0, label, OBJPROP_TEXT, txt);
}
//+------------------------------------------------------------------+
