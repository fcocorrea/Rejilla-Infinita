//+------------------------------------------------------------------+
//|                                                 ScalpingGrid.mq5 |
//|                        Scalping Grid Expert Advisor              |
//|              Infinite equidistant grid with ATR filter,          |
//|                 hedging imbalance guard, and trailing stop.      |
//|              + Dynamic Risk Mitigation Module                    |
//+------------------------------------------------------------------+
#property copyright "ScalpingGrid EA"
#property link      ""
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumeración para seleccionar el tipo de orden de la grilla       |
//+------------------------------------------------------------------+
enum ENUM_ORDER_GRID_TYPE
{
   GRID_LIMIT = 0,  // Limit (Buy Limit / Sell Limit)
   GRID_STOP  = 1   // Stop  (Buy Stop  / Sell Stop)
};

//+------------------------------------------------------------------+
//| Parámetros de entrada (Inputs)                                   |
//+------------------------------------------------------------------+
// --- Grid ---
input double              inpDistance      = 100;        // Distancia entre niveles de grilla (precio)
input ENUM_ORDER_GRID_TYPE inpOrderType    = GRID_LIMIT; // Tipo de orden: Limit o Stop
input double              inpVolume        = 0.01;       // Volumen por operación (lotes)
input ulong               inpMagicNum      = 123456;     // Magic Number del EA

// --- Take Profit / Stop Loss ---
input double              inpTP            = 100;        // Take Profit en unidades de precio (0 = desactivado)
input double              inpSL            = 50;         // Stop Loss en unidades de precio (0 = modo cobertura)

// --- Hedging Imbalance Guard ---
input int                 inpMaxImbalance  = 2;          // Desequilibrio máximo compras/ventas

// --- Trailing Stop ---
input double              inpTrailingStop  = 50;         // Trailing Stop en unidades de precio (0 = desactivado)
input double              inpTrailingStep  = 50;         // Paso mínimo del Trailing Stop

// --- Filtro ATR ---
input int                 inpATRPeriod     = 14;         // Período del ATR
input double              inpMinATR        = 0.0;        // ATR mínimo (≤ elimina órdenes pendientes)
input double              inpMaxATR        = 0.0;        // ATR máximo (≥ elimina órdenes pendientes)

// --- Grid Depth ---
input int                 inpGridLevels    = 10;         // Cantidad de niveles por lado de la grilla

//+------------------------------------------------------------------+
//| Variables globales                                               |
//+------------------------------------------------------------------+
CTrade   g_trade;          // Objeto de operaciones
int      g_atrHandle;      // Handle del indicador ATR
double   g_atrBuffer[];    // Buffer ATR
double   g_tickSize;       // Tamaño mínimo de tick
int      g_digits;         // Dígitos del símbolo

// --- Variables Dinámicas (Módulo de Mitigación de Riesgo) ---
double   g_initialBalance;            // Balance al iniciar el EA
double   g_dynDistance;               // Distancia dinámica calculada
double   g_dynTP;                     // TP dinámico
double   g_dynSL;                     // SL dinámico
double   g_dynTrailingStop;           // Trailing Stop dinámico

bool               g_imbalanceProtectionActive = false; // Estado del Módulo 1
ENUM_POSITION_TYPE g_minorityType;                      // Lado con menos órdenes (Buy o Sell)

//+------------------------------------------------------------------+
//| OnInit — Inicialización del EA                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Validaciones iniciales se mantienen igual ---
   if(inpDistance <= 0.0 || inpVolume <= 0.0 || inpATRPeriod <= 0 || inpGridLevels <= 0) return(INIT_PARAMETERS_INCORRECT);
   
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, inpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE) return(INIT_FAILED);
   ArraySetAsSeries(g_atrBuffer, true);

   g_trade.SetExpertMagicNumber(inpMagicNum);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);

   // --- Inicializar variables dinámicas ---
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dynDistance = inpDistance;
   g_dynTP = inpTP;
   g_dynSL = inpSL;
   g_dynTrailingStop = inpTrailingStop;

   Print("ScalpingGrid EA inicializado. Módulo de Mitigación activado.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit — Limpieza al remover el EA                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   DeleteAllPendingOrders();
}

//+------------------------------------------------------------------+
//| OnTick — Evento principal en cada tick                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(CopyBuffer(g_atrHandle, 0, 0, 1, g_atrBuffer) <= 0) return;
   bool isAtrValid = CheckATRFilter(g_atrBuffer[0]);

   if(!isAtrValid && inpSL > 0.0)
   {
      DeleteAllPendingOrders();
      return;
   }

   int buys = 0, sells = 0;
   CountPositions(buys, sells);

   // === 1. MÓDULO DE MITIGACIÓN DE RIESGO ===
   UpdateDrawdownMultiplier();             // Escala parámetros si hay Drawdown
   ManageImbalanceProtection(buys, sells); // Protege contra desequilibrio extremo

   // === 2. LÓGICA CORE DE GRILLA ===
   PruneImbalancedOrders(buys, sells);
   ManageGrid(buys, sells, isAtrValid);

   // === 3. TRAILING STOP ===
   if(g_dynTrailingStop > 0.0) ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| MÓDULO 2: Escalado Adaptativo por Drawdown                       |
//+------------------------------------------------------------------+
void UpdateDrawdownMultiplier()
{
   // Si el SL es 0 (modo cobertura puro), no aplicamos escalado
   if (inpSL == 0.0) 
   {
      g_dynDistance = inpDistance;
      g_dynTP = inpTP;
      g_dynSL = inpSL;
      g_dynTrailingStop = inpTrailingStop;
      return;
   }

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPct = (g_initialBalance - currentEquity) / g_initialBalance;

   // Si la caída es igual o superior al 50%
   if (drawdownPct >= 0.50)
   {
      // Regla de Escalamiento por Tramos (Step Logic) al 10%
      // Ej: Si DD es 55%, stepDD será 0.50. Si llega al 60%, será 0.60.
      double stepDD = MathFloor(drawdownPct / 0.10) * 0.10;
      
      // Cálculo del multiplicador (M)
      double M = 1.0 / (1.0 - stepDD);

      // Aplicar multiplicador a los parámetros para NUEVAS operaciones
      g_dynDistance = inpDistance * M;
      g_dynTP = inpTP * M;
      g_dynSL = inpSL * M;
      g_dynTrailingStop = inpTrailingStop * M;
   }
   else
   {
      // Escalamiento hacia abajo (Recuperación)
      // Restablece los parámetros originales inmediatamente
      g_dynDistance = inpDistance;
      g_dynTP = inpTP;
      g_dynSL = inpSL;
      g_dynTrailingStop = inpTrailingStop;
   }
}

//+------------------------------------------------------------------+
//| MÓDULO 1: Protección por Desequilibrio (Hedging Logic)           |
//+------------------------------------------------------------------+
void ManageImbalanceProtection(const int buys, const int sells)
{
   bool hasZeroSL = false;
   double floatingPL = 0.0;
   int total = PositionsTotal();

   // 1. Recopilar datos de posiciones
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)inpMagicNum) continue;
      
      if(PositionGetDouble(POSITION_SL) == 0.0) hasZeroSL = true;
      floatingPL += PositionGetDouble(POSITION_PROFIT);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   int imbalance = MathAbs(buys - sells);

   // 2. Evaluar Condiciones (A, B y C)
   // A: Alguna orden tiene SL == 0
   // B: Valor absoluto de P/L es mayor al Equity
   // C: Desequilibrio mayor a inpMaxImbalance
   if(hasZeroSL && MathAbs(floatingPL) > equity && imbalance > inpMaxImbalance)
   {
      g_imbalanceProtectionActive = true;
      // Identificar el lado con menor exposición (minoridad)
      if(buys < sells) g_minorityType = POSITION_TYPE_BUY;
      else if(sells < buys) g_minorityType = POSITION_TYPE_SELL;
      else g_imbalanceProtectionActive = false; // Empate, no hay minoría
   }
   else
   {
      g_imbalanceProtectionActive = false; // Condiciones no se cumplen, desactivar
   }

   // 3. Ejecutar Acción o Restauración
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)inpMagicNum) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentSL = PositionGetDouble(POSITION_SL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      // Si la protección está activa y la orden pertenece al lado minoritario
      if(g_imbalanceProtectionActive && posType == g_minorityType)
      {
         // Eliminar Take Profit
         if(currentTP != 0.0)
         {
            g_trade.PositionModify(ticket, currentSL, 0.0);
         }
         // (El Trailing Stop se detiene directamente dentro de ManageTrailingStop)
      }
      else
      {
         // PERSISTENCIA: Restaurar el TP si la protección se desactivó o no aplica a este lado
         if(currentTP == 0.0 && g_dynTP > 0.0)
         {
            double expectedTP = 0.0;
            if(posType == POSITION_TYPE_BUY) expectedTP = NormalizeToTickSize(openPrice + g_dynTP);
            else if(posType == POSITION_TYPE_SELL) expectedTP = NormalizeToTickSize(openPrice - g_dynTP);

            // Gestión de Errores: Solo modificar si el TP esperado es diferente del actual (evita spam al servidor)
            if(expectedTP != 0.0 && MathAbs(currentTP - expectedTP) > g_tickSize)
            {
               g_trade.PositionModify(ticket, currentSL, expectedTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ManageTrailingStop — Actualizado con Protección y Dinamismo      |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double trailDistance = g_dynTrailingStop;
   double stepDistance  = inpTrailingStep;

   int total = PositionsTotal();
   for(int i = 0; i < total && !IsStopped(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)inpMagicNum) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      // BLOQUEO POR PROTECCIÓN: Si está activa la protección para este lado, salta el trailing
      if(g_imbalanceProtectionActive && posType == g_minorityType) continue;

      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - openPrice > trailDistance)
         {
            double newSL = NormalizeToTickSize(bid - trailDistance);
            if(newSL > currentSL + stepDistance || currentSL <= 0.0)
            {
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - ask > trailDistance)
         {
            double newSL = NormalizeToTickSize(ask + trailDistance);
            if(newSL < currentSL - stepDistance || currentSL <= 0.0)
            {
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| PlaceGridOrder — Usa variables dinámicas (g_dyn...)              |
//+------------------------------------------------------------------+
bool PlaceGridOrder(const ENUM_ORDER_TYPE orderType, const double price)
{
   double normalizedPrice = NormalizeToTickSize(price);
   if(IsGridLevelOccupied(normalizedPrice)) return false; 

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_SELL_STOP)
   {
      if(MathAbs(normalizedPrice - currentAsk) <= minDistance) return false; 
   }
   else if(orderType == ORDER_TYPE_SELL_LIMIT || orderType == ORDER_TYPE_BUY_STOP)
   {
      if(MathAbs(normalizedPrice - currentBid) <= minDistance) return false;
   }

   double tp = 0.0;
   double sl = 0.0;
   
   if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP)
   {
      if(g_dynTP > 0.0) tp = NormalizeToTickSize(normalizedPrice + g_dynTP);
      if(g_dynSL > 0.0) sl = NormalizeToTickSize(normalizedPrice - g_dynSL);
   }
   else if(orderType == ORDER_TYPE_SELL_LIMIT || orderType == ORDER_TYPE_SELL_STOP)
   {
      if(g_dynTP > 0.0) tp = NormalizeToTickSize(normalizedPrice - g_dynTP);
      if(g_dynSL > 0.0) sl = NormalizeToTickSize(normalizedPrice + g_dynSL);
   }

   switch(orderType)
   {
      case ORDER_TYPE_BUY_LIMIT: return g_trade.BuyLimit(inpVolume, normalizedPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ScalpingGrid BuyLimit");
      case ORDER_TYPE_SELL_LIMIT: return g_trade.SellLimit(inpVolume, normalizedPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ScalpingGrid SellLimit");
      case ORDER_TYPE_BUY_STOP: return g_trade.BuyStop(inpVolume, normalizedPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ScalpingGrid BuyStop");
      case ORDER_TYPE_SELL_STOP: return g_trade.SellStop(inpVolume, normalizedPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ScalpingGrid SellStop");
   }
   return false;
}

//+------------------------------------------------------------------+
//| ModifyGridOrder — Usa variables dinámicas (g_dyn...)             |
//+------------------------------------------------------------------+
bool ModifyGridOrder(ulong ticket, ENUM_ORDER_TYPE orderType, double newPrice)
{
   double normalizedPrice = NormalizeToTickSize(newPrice);
   double tp = 0.0;
   double sl = 0.0;

   if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP)
   {
      if(g_dynTP > 0.0) tp = NormalizeToTickSize(normalizedPrice + g_dynTP);
      if(g_dynSL > 0.0) sl = NormalizeToTickSize(normalizedPrice - g_dynSL);
   }
   else if(orderType == ORDER_TYPE_SELL_LIMIT || orderType == ORDER_TYPE_SELL_STOP)
   {
      if(g_dynTP > 0.0) tp = NormalizeToTickSize(normalizedPrice - g_dynTP);
      if(g_dynSL > 0.0) sl = NormalizeToTickSize(normalizedPrice + g_dynSL);
   }

   return g_trade.OrderModify(ticket, normalizedPrice, sl, tp, ORDER_TIME_GTC, 0);
}

//+------------------------------------------------------------------+
//| IsGridLevelOccupied — Usa distancia dinámica para la tolerancia  |
//+------------------------------------------------------------------+
bool IsGridLevelOccupied(const double price)
{
   double tolerance = g_dynDistance * 0.4; // Tolerancia escalada

   int totalOrders = OrdersTotal();
   for(int i = 0; i < totalOrders && !IsStopped(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)inpMagicNum) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) <= tolerance) return true;
   }

   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions && !IsStopped(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)inpMagicNum) continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) <= tolerance) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ManageGrid — Usa g_dynDistance para calcular anclajes            |
//+------------------------------------------------------------------+
void ManageGrid(const int buys, const int sells, const bool isAtrValid)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   double anchorAsk = MathCeil(ask / g_dynDistance) * g_dynDistance;
   double anchorBid = MathFloor(bid / g_dynDistance) * g_dynDistance;

   ENUM_ORDER_TYPE aboveType = (inpOrderType == GRID_LIMIT) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_STOP;
   ENUM_ORDER_TYPE belowType = (inpOrderType == GRID_LIMIT) ? ORDER_TYPE_BUY_LIMIT  : ORDER_TYPE_SELL_STOP;

   int allowedBuys = inpGridLevels;
   int allowedSells = inpGridLevels;

   if(inpSL == 0.0) 
   {
      int currentMaxImbalance = isAtrValid ? inpMaxImbalance : 0;
      allowedSells = (int)MathMax(0, currentMaxImbalance - (sells - buys));
      allowedBuys  = (int)MathMax(0, currentMaxImbalance - (buys - sells));

      if(allowedBuys > inpGridLevels) allowedBuys = inpGridLevels;
      if(allowedSells > inpGridLevels) allowedSells = inpGridLevels;
   }

   int allowedAbove = (aboveType == ORDER_TYPE_SELL_LIMIT || aboveType == ORDER_TYPE_SELL_STOP) ? allowedSells : allowedBuys;
   int allowedBelow = (aboveType == ORDER_TYPE_SELL_LIMIT || aboveType == ORDER_TYPE_SELL_STOP) ? allowedBuys : allowedSells;

   SyncGridLevels(aboveType, anchorAsk, true, allowedAbove);
   SyncGridLevels(belowType, anchorBid, false, allowedBelow);
}

//+------------------------------------------------------------------+
//| SyncGridLevels — Usa g_dynDistance para espaciado ideal          |
//+------------------------------------------------------------------+
void SyncGridLevels(ENUM_ORDER_TYPE orderType, double anchorPrice, bool isAbove, int maxAllowed)
{
   double idealPrices[];
   ArrayResize(idealPrices, maxAllowed);
   for(int n = 0; n < maxAllowed; n++)
   {
      if(isAbove) idealPrices[n] = NormalizeToTickSize(anchorPrice + n * g_dynDistance);
      else        idealPrices[n] = NormalizeToTickSize(anchorPrice - n * g_dynDistance);
   }

   bool priceOccupied[];
   ArrayResize(priceOccupied, maxAllowed);
   ArrayInitialize(priceOccupied, false);

   for(int n = 0; n < maxAllowed; n++)
   {
      if(IsGridLevelOccupied(idealPrices[n])) priceOccupied[n] = true;
   }

   ulong misplacedTickets[];
   int misplacedCount = 0;

   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0 && !IsStopped(); i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)inpMagicNum) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != orderType) continue;

      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      bool isIdeal = false;
      
      for(int n = 0; n < maxAllowed; n++)
      {
         if(MathAbs(orderPrice - idealPrices[n]) <= g_dynDistance * 0.4)
         {
            isIdeal = true;
            break;
         }
      }

      if(!isIdeal)
      {
         ArrayResize(misplacedTickets, misplacedCount + 1);
         misplacedTickets[misplacedCount] = ticket;
         misplacedCount++;
      }
   }

   int misplacedIndex = 0;
   for(int n = 0; n < maxAllowed && !IsStopped(); n++)
   {
      if(priceOccupied[n]) continue; 

      if(misplacedIndex < misplacedCount)
      {
         ModifyGridOrder(misplacedTickets[misplacedIndex], orderType, idealPrices[n]);
         misplacedIndex++;
      }
      else PlaceGridOrder(orderType, idealPrices[n]);
   }
}

//+------------------------------------------------------------------+
//| Funciones de Utilidad                                            |
//+------------------------------------------------------------------+
bool CheckATRFilter(const double currentATR) {
   if(inpMinATR <= 0.0 && inpMaxATR <= 0.0) return true;
   if(inpMinATR > 0.0 && currentATR <= inpMinATR) return false;
   if(inpMaxATR > 0.0 && currentATR >= inpMaxATR) return false;
   return true;
}

void CountPositions(int &buys, int &sells) {
   buys = 0; sells = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total && !IsStopped(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)inpMagicNum) continue;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY) buys++;
      else if(posType == POSITION_TYPE_SELL) sells++;
   }
}

double NormalizeToTickSize(const double price) {
   if(g_tickSize <= 0.0) return NormalizeDouble(price, g_digits);
   return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, g_digits);
}

void DeleteAllPendingOrders() {
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0 && !IsStopped(); i--) {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)inpMagicNum) continue;
      g_trade.OrderDelete(ticket);
   }
}

void CountPendingOrders(int &pendingBuys, int &pendingSells) {
   pendingBuys = 0; pendingSells = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total && !IsStopped(); i++) {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)inpMagicNum) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP) pendingBuys++;
      else if(type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP) pendingSells++;
   }
}

void PruneImbalancedOrders(const int buys, const int sells) {
   if(inpSL != 0.0) return;
   int pendingBuys = 0, pendingSells = 0;
   CountPendingOrders(pendingBuys, pendingSells);
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0 && !IsStopped(); i--) {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != (long)inpMagicNum) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP) {
         if((sells + pendingSells) - buys > inpMaxImbalance) {
            if(g_trade.OrderDelete(ticket)) pendingSells--;
         }
      } else if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP) {
         if((buys + pendingBuys) - sells > inpMaxImbalance) {
            if(g_trade.OrderDelete(ticket)) pendingBuys--;
         }
      }
   }
}
//+------------------------------------------------------------------+