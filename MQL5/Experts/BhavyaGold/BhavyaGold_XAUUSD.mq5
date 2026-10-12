#property strict
#property version "1.00"
#property description "XAUUSD M5 box breakout/retest research EA. No verified profitability claim."
#include <Trade/Trade.mqh>
#include "GoldCore.mqh"

input group "Account and risk"
input bool   InpAllowRealAccount=false;
input ulong  InpMagic=26100601;
input double InpRiskPercent=0.25;
input double InpDailyLossPercent=1.00;
input double InpDailyPeakLossPercent=1.00;
input double InpOverallPeakLossPercent=5.00;
input int    InpMaxTradesPerDay=2;
input int    InpCooldownMinutes=15;
input double InpCommissionPerLotRoundTrip=8.00; // ACCOUNT currency, not gold price units.

input group "Closed-bar trend filters"
input int    InpH1FastEMA=20;
input int    InpH1SlowEMA=50;
input int    InpADXPeriod=14;
input double InpMinADX=18.0;
input bool   InpUseD1Filter=true;
input int    InpD1FastEMA=20;
input int    InpD1SlowEMA=50;
input int    InpATRPeriod=14;

input group "M5 box and retest"
input int    InpBoxBars=12;
input double InpMinBoxATR=1.0;
input double InpMaxBoxATR=4.0;
input double InpBreakoutBufferATR=0.10;
input double InpBreakoutMaxExtensionATR=0.80;
input double InpMinBodyATR=0.15;
input double InpMaxSignalRangeATR=2.50;
input int    InpRetestBars=6;
input double InpRetestTouchATR=0.25;
input double InpRetestPenetrationATR=0.50;
input double InpRetestCloseBufferATR=0.05;
input double InpMaxEntryMoveATR=0.35;
input double InpMaxEntryExtensionATR=0.90;

input group "Stops and exits"
input double InpStopATR=1.50;
input double InpMaxStopATR=3.00;
input double InpRewardRisk=2.00;
input double InpBreakEvenAtR=1.00;
input double InpBreakEvenLockR=0.05;
input bool   InpUseATRTrail=true;
input double InpTrailStartR=1.50;
input double InpTrailATR=1.20;
input int    InpMaxHoldMinutes=120;
input bool   InpCloseOutsideSession=true;

input group "Broker-server session and execution"
input int    InpSessionStartHour=7;
input int    InpSessionEndHour=20;
input int    InpFridayStopHour=16;
input double InpMaxSpreadPrice=0.50; // USD per ounce: 0.50 means a $0.50 gold quote spread.
input double InpMaxSpreadATR=0.15;
input double InpSlippagePrice=0.30;  // Converted to the broker's point/deviation units.

input group "Optional manual news blackouts"
input bool   InpUseNewsBlackouts=false;
input string InpNewsFile="gold_news.csv"; // Terminal Common/Files, broker-server timestamps.
input int    InpNewsMinutesBefore=30;
input int    InpNewsMinutesAfter=15;

input group "Result exports"
input bool   InpExportResults=true;
input string InpExportPrefix="BhavyaGold";

CTrade g_trade;
string g_symbol,g_key,g_leaseKey,g_state="Starting",g_exportStem;
bool g_tester=false,g_initialized=false,g_ownsLease=false,g_storageOK=true;
bool g_dayLocked=false,g_campaignLocked=false;
bool g_protectiveExitRequired=false;
double g_leaseValue=0.0,g_dayStart=0.0,g_dayPeak=0.0,g_campaignPeak=0.0;
double g_entryBudget=0.0,g_point=0.0,g_tickSize=0.0,g_lastATR=0.0;
ulong g_originalRiskId=0;
double g_originalRiskDistance=0.0;
int g_digits=0,g_day=0,g_tradesToday=0,g_equityFile=INVALID_HANDLE;
datetime g_lastBar=0,g_lastEntry=0,g_lastCloseAttempt=0;
int g_atr=INVALID_HANDLE,g_h1Fast=INVALID_HANDLE,g_h1Slow=INVALID_HANDLE;
int g_adx=INVALID_HANDLE,g_d1Fast=INVALID_HANDLE,g_d1Slow=INVALID_HANDLE;
int g_pendingDirection=0;
double g_pendingLevel=0.0;
datetime g_breakoutBar=0;

uint HashText(const string value)
{
   uint hash=2166136261;
   for(int i=0;i<StringLen(value);i++)
      hash=(hash^(uint)StringGetCharacter(value,i))*16777619;
   return hash;
}

string SafeName(const string value)
{
   string result="";
   for(int i=0;i<StringLen(value) && i<24;i++)
   {
      ushort c=StringGetCharacter(value,i);
      if((c>=65 && c<=90) || (c>=97 && c<=122) || (c>=48 && c<=57) || c==95 || c==45)
         result+=StringSubstr(value,i,1);
      else result+="_";
   }
   return result;
}

int ServerDay(const datetime now)
{
   MqlDateTime parts;
   TimeToStruct(now,parts);
   return parts.year*10000+parts.mon*100+parts.day;
}

datetime ServerMidnight(const datetime now)
{
   MqlDateTime parts;
   TimeToStruct(now,parts);
   parts.hour=0; parts.min=0; parts.sec=0;
   return StructToTime(parts);
}

void ResetPending()
{
   g_pendingDirection=0; g_pendingLevel=0.0; g_breakoutBar=0;
}

bool SaveKey(const string suffix,const double value)
{
   if(g_tester) return true;
   ResetLastError();
   if(GlobalVariableSet(g_key+suffix,value)==0)
   {
      Print("Risk state could not be saved. Entries blocked. Error ",GetLastError());
      g_storageOK=false;
      return false;
   }
   return true;
}

void SaveRisk()
{
   SaveKey(".day",(double)g_day);
   SaveKey(".start",g_dayStart);
   SaveKey(".dpeak",g_dayPeak);
   SaveKey(".peak",g_campaignPeak);
   SaveKey(".dhalt",g_dayLocked ? 1.0 : 0.0);
   SaveKey(".halt",g_campaignLocked ? 1.0 : 0.0);
   SaveKey(".budget",g_entryBudget);
   SaveKey(".unsafe",g_protectiveExitRequired ? 1.0 : 0.0);
}

bool AcquireLease()
{
   if(g_tester) { g_ownsLease=true; return true; }
   if(!GlobalVariableCheck(g_leaseKey) && !GlobalVariableTemp(g_leaseKey)) return false;
   double old=GlobalVariableGet(g_leaseKey);
   double now=(double)TimeLocal();
   if(old>now) return false;
   g_leaseValue=now+15.0;
   g_ownsLease=GlobalVariableSetOnCondition(g_leaseKey,g_leaseValue,old);
   return g_ownsLease;
}

bool OwnLease()
{
   if(g_tester) return true;
   if(!g_ownsLease || !GlobalVariableCheck(g_leaseKey)) return false;
   if(GlobalVariableGet(g_leaseKey)!=g_leaseValue)
   {
      g_ownsLease=false;
      g_state="Another instance owns this symbol/magic; this instance is inactive";
      return false;
   }
   return true;
}

void RenewLease()
{
   if(g_tester || !OwnLease()) return;
   double next=(double)TimeLocal()+15.0;
   if(GlobalVariableSetOnCondition(g_leaseKey,next,g_leaseValue)) g_leaseValue=next;
   else g_ownsLease=false;
}

void ReleaseLease()
{
   if(!g_tester && g_ownsLease)
      GlobalVariableSetOnCondition(g_leaseKey,0.0,g_leaseValue);
   g_ownsLease=false;
}

bool LoadRisk()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=0.0) return false;
   if(!g_tester && GlobalVariableCheck(g_key+".peak"))
   {
      if(!GlobalVariableCheck(g_key+".day") || !GlobalVariableCheck(g_key+".start") ||
         !GlobalVariableCheck(g_key+".dpeak") || !GlobalVariableCheck(g_key+".halt") ||
         !GlobalVariableCheck(g_key+".dhalt"))
      { Print("Incomplete persistent risk state. Repair before starting."); return false; }
      g_day=(int)GlobalVariableGet(g_key+".day");
      g_dayStart=GlobalVariableGet(g_key+".start");
      g_dayPeak=GlobalVariableGet(g_key+".dpeak");
      g_campaignPeak=GlobalVariableGet(g_key+".peak");
      g_dayLocked=(GlobalVariableGet(g_key+".dhalt")>0.0);
      g_campaignLocked=(GlobalVariableGet(g_key+".halt")>0.0);
      g_entryBudget=GlobalVariableCheck(g_key+".budget") ? GlobalVariableGet(g_key+".budget") : 0.0;
      g_protectiveExitRequired=GlobalVariableCheck(g_key+".unsafe") && GlobalVariableGet(g_key+".unsafe")>0.0;
      if(g_dayStart<=0.0 || g_dayPeak<=0.0 || g_campaignPeak<=0.0) return false;
   }
   else
   {
      g_day=ServerDay(TimeCurrent());
      g_dayStart=equity; g_dayPeak=equity; g_campaignPeak=equity;
      g_dayLocked=false; g_campaignLocked=false;
   }
   SaveRisk();
   return g_storageOK;
}

void UpdateRisk(const datetime now)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   bool changed=false;
   int day=ServerDay(now);
   if(day!=g_day)
   {
      g_day=day; g_dayStart=equity; g_dayPeak=equity;
      g_dayLocked=false; ResetPending(); changed=true;
   }
   if(equity>g_dayPeak) { g_dayPeak=equity; changed=true; }
   if(equity>g_campaignPeak) { g_campaignPeak=equity; changed=true; }
   if(!g_dayLocked && (equity<=g_dayStart*(1.0-InpDailyLossPercent/100.0) ||
      equity<=g_dayPeak*(1.0-InpDailyPeakLossPercent/100.0)))
   {
      g_dayLocked=true; changed=true;
      Print("Daily equity guard triggered. Own positions will be closed when executable.");
   }
   if(!g_campaignLocked && equity<=g_campaignPeak*(1.0-InpOverallPeakLossPercent/100.0))
   {
      g_campaignLocked=true; changed=true;
      Print("Campaign equity guard triggered. Persistent entry lock is active.");
   }
   if(changed) { SaveRisk(); if(!g_tester) GlobalVariablesFlush(); }
}

bool SessionOpen(const datetime now)
{
   MqlDateTime parts;
   TimeToStruct(now,parts);
   if(parts.day_of_week==0 || parts.day_of_week==6) return false;
   if(parts.day_of_week==5 && parts.hour>=InpFridayStopHour) return false;
   return BGInSession(parts.hour,InpSessionStartHour,InpSessionEndHour);
}

bool TradingPermission()
{
   return (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          (bool)MQLInfoInteger(MQL_TRADE_ALLOWED) &&
          (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
          (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
}

bool SelectedOwnPosition()
{
   return PositionGetString(POSITION_SYMBOL)==g_symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
}

bool HasSymbolExposure()
{
   // Includes manual/foreign positions and pending orders. Important on netting accounts.
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==g_symbol) return true;
   for(int i=OrdersTotal()-1;i>=0;i--)
      if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==g_symbol) return true;
   return false;
}

bool HasOwnExposure()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && SelectedOwnPosition()) return true;
   for(int i=OrdersTotal()-1;i>=0;i--)
      if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==g_symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagic) return true;
   return false;
}

bool AcceptedResult()
{
   uint code=g_trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL || code==TRADE_RETCODE_PLACED;
}

void PrintTradeFailure(const string operation)
{
   Print(operation,": ",g_trade.ResultRetcode()," ",g_trade.ResultRetcodeDescription());
}

void CloseOwnPositions(const string reason)
{
   g_state=reason; ResetPending();
   datetime now=TimeCurrent();
   if(now-g_lastCloseAttempt<3 || !TradingPermission()) return;
   g_lastCloseAttempt=now;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !SelectedOwnPosition()) continue;
      if(!g_trade.PositionClose(ticket) || !AcceptedResult()) PrintTradeFailure(reason);
   }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=g_symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if(!g_trade.OrderDelete(ticket) || !AcceptedResult()) PrintTradeFailure("Cancel own order");
   }
}

void RefreshDailyEntries(const datetime now)
{
   g_tradesToday=0; g_lastEntry=0;
   if(!HistorySelect(ServerMidnight(now),now))
   { g_tradesToday=InpMaxTradesPerDay; g_state="History unavailable; entries blocked"; return; }
   ulong orders[];
   int count=0;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=g_symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic ||
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
      ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
      bool seen=false;
      for(int j=0;j<count;j++) if(orders[j]==order) { seen=true; break; }
      if(!seen) { ArrayResize(orders,count+1); orders[count++]=order; }
      datetime entered=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(entered>g_lastEntry) g_lastEntry=entered;
   }
   g_tradesToday=count;
}

bool ReadIndicator(const int handle,const int buffer,const int shift,double &value)
{
   double data[1];
   if(handle==INVALID_HANDLE || CopyBuffer(handle,buffer,shift,1,data)!=1) return false;
   value=data[0];
   return MathIsValidNumber(value) && value!=EMPTY_VALUE;
}

bool TrendDirection(int &direction)
{
   direction=0;
   double fast,previous_fast,slow,adx,plus_di,minus_di;
   if(!ReadIndicator(g_h1Fast,0,1,fast) || !ReadIndicator(g_h1Fast,0,2,previous_fast) ||
      !ReadIndicator(g_h1Slow,0,1,slow) || !ReadIndicator(g_adx,0,1,adx) ||
      !ReadIndicator(g_adx,1,1,plus_di) || !ReadIndicator(g_adx,2,1,minus_di)) return false;
   double close=iClose(g_symbol,PERIOD_H1,1);
   if(close<=0.0) return false;
   if(adx<InpMinADX) return true;
   if(fast>slow && fast>previous_fast && close>fast && plus_di>minus_di) direction=1;
   if(fast<slow && fast<previous_fast && close<fast && minus_di>plus_di) direction=-1;
   if(InpUseD1Filter)
   {
      double dfast,dslow;
      if(!ReadIndicator(g_d1Fast,0,1,dfast) || !ReadIndicator(g_d1Slow,0,1,dslow)) return false;
      double dclose=iClose(g_symbol,PERIOD_D1,1);
      if(dclose<=0.0) return false;
      if(direction==1 && !(dfast>dslow && dclose>dfast)) direction=0;
      if(direction==-1 && !(dfast<dslow && dclose<dfast)) direction=0;
   }
   return true;
}

datetime ParseNewsTime(const string value)
{
   int length=StringLen(value);
   if(length!=16 && length!=19) return 0;
   if(StringGetCharacter(value,4)!=46 || StringGetCharacter(value,7)!=46 ||
      StringGetCharacter(value,10)!=32 || StringGetCharacter(value,13)!=58) return 0;
   for(int i=0;i<length;i++)
   {
      if(i==4 || i==7 || i==10 || i==13 || (length==19 && i==16)) continue;
      ushort c=StringGetCharacter(value,i);
      if(c<48 || c>57) return 0;
   }
   if(length==19 && StringGetCharacter(value,16)!=58) return 0;
   datetime parsed=StringToTime(value);
   int format=TIME_DATE|TIME_MINUTES;
   if(length==19) format=TIME_DATE|TIME_SECONDS;
   return TimeToString(parsed,format)==value ? parsed : 0;
}

bool NewsBlocked(const datetime now)
{
   if(!InpUseNewsBlackouts) return false;
   int handle=FileOpen(InpNewsFile,FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON,',',CP_UTF8);
   if(handle==INVALID_HANDLE) { g_state="News schedule missing; entries blocked"; return true; }
   datetime coverage_start=0,coverage_end=0;
   bool blocked=false,malformed=false;
   while(!FileIsEnding(handle))
   {
      string first=FileReadString(handle);
      string second="";
      if(!FileIsLineEnding(handle) && !FileIsEnding(handle)) second=FileReadString(handle);
      // Consume any extra columns without mistaking them for another event.
      while(!FileIsLineEnding(handle) && !FileIsEnding(handle)) FileReadString(handle);
      if(first=="COVERAGE_START") coverage_start=ParseNewsTime(second);
      else if(first=="COVERAGE_END") coverage_end=ParseNewsTime(second);
      else if(first!="server_time" && first!="" && StringFind(first,"#")!=0)
      {
         datetime event_time=ParseNewsTime(first);
         if(event_time==0) malformed=true;
         if(event_time>0 && now>=event_time-InpNewsMinutesBefore*60 &&
            now<=event_time+InpNewsMinutesAfter*60) blocked=true;
      }
   }
   FileClose(handle);
   if(malformed) { g_state="Malformed news schedule; entries blocked"; return true; }
   if(coverage_start<=0 || coverage_end<=coverage_start ||
      now-InpNewsMinutesAfter*60<coverage_start || now+InpNewsMinutesBefore*60>coverage_end)
   { g_state="News schedule has no verified coverage for this time; entries blocked"; return true; }
   if(blocked) g_state="Inside a scheduled news blackout";
   return blocked;
}

double RiskBudget()
{
   return BGRiskBudget(AccountInfoDouble(ACCOUNT_EQUITY),InpRiskPercent,
          BGRiskFloor(g_dayStart,g_dayPeak,g_campaignPeak,InpDailyLossPercent,
                      InpDailyPeakLossPercent,InpOverallPeakLossPercent));
}

double InitialRiskDistance()
{
   ulong id=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(id==g_originalRiskId && g_originalRiskDistance>0.0) return g_originalRiskDistance;
   string suffix=".r"+(string)id;
   if(!g_tester && GlobalVariableCheck(g_key+suffix))
      return GlobalVariableGet(g_key+suffix);
   // TP is never moved by this EA, so it preserves an original-R estimate after restart.
   double value=MathAbs(PositionGetDouble(POSITION_TP)-PositionGetDouble(POSITION_PRICE_OPEN))/InpRewardRisk;
   return value;
}

bool ProtectOwnPositions()
{
   bool saw_position=false,unsafe=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !SelectedOwnPosition()) continue;
      saw_position=true;
      double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP),volume=PositionGetDouble(POSITION_VOLUME);
      if(sl<=0.0 || tp<=0.0) { unsafe=true; continue; }
      if(g_entryBudget>0.0)
      {
         ENUM_ORDER_TYPE side=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double loss=0.0;
         if(!OrderCalcProfit(side,g_symbol,volume,open,sl,loss) ||
            MathAbs(loss)+volume*InpCommissionPerLotRoundTrip>g_entryBudget*1.01)
         { unsafe=true; continue; }
         SaveKey(".r"+(string)(ulong)PositionGetInteger(POSITION_IDENTIFIER),MathAbs(open-sl));
         g_originalRiskId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
         g_originalRiskDistance=MathAbs(open-sl);
      }
   }
   if(unsafe)
   {
      g_protectiveExitRequired=true;
      SaveKey(".unsafe",1.0);
   }
   if(g_protectiveExitRequired && HasOwnExposure())
   {
      CloseOwnPositions("Protective exit: missing bracket or fill risk above budget");
      return false; // Retry the protective exit until the position is actually gone.
   }
   if(g_protectiveExitRequired && !HasOwnExposure())
   {
      g_protectiveExitRequired=false; g_entryBudget=0.0;
      SaveKey(".unsafe",0.0); SaveKey(".budget",0.0);
   }
   if(saw_position) { g_entryBudget=0.0; SaveKey(".budget",0.0); }
   return !g_protectiveExitRequired;
}

void ManagePositions(const datetime now)
{
   if(!ProtectOwnPositions()) return;
   if(g_dayLocked || g_campaignLocked || g_protectiveExitRequired || !g_storageOK)
   { CloseOwnPositions("Equity/storage guard active"); return; }
   if(InpCloseOutsideSession && !SessionOpen(now))
   { CloseOwnPositions("Session closed; flattening own positions"); return; }
   MqlTick quote;
   if(!SymbolInfoTick(g_symbol,quote) || quote.bid<=0.0 || quote.ask<=0.0) return;
   double atr=0.0;
   bool have_atr=ReadIndicator(g_atr,0,1,atr) && atr>0.0;
   long stops=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double clearance=MathMax((double)stops,(double)freeze)*g_point+2.0*g_tickSize;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !SelectedOwnPosition()) continue;
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      if(now-opened>=InpMaxHoldMinutes*60)
      { CloseOwnPositions("Maximum holding time reached"); return; }
      double risk=InitialRiskDistance();
      if(risk<=0.0 || !TradingPermission()) continue;
      bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP),price=buy ? quote.bid : quote.ask;
      double reward=buy ? price-open : open-price;
      double multiple=reward/risk,candidate=sl;
      if(multiple>=InpBreakEvenAtR)
      {
         double be=buy ? open+InpBreakEvenLockR*risk : open-InpBreakEvenLockR*risk;
         candidate=buy ? MathMax(candidate,be) : MathMin(candidate,be);
      }
      if(InpUseATRTrail && have_atr && multiple>=InpTrailStartR)
      {
         double trail=buy ? quote.bid-InpTrailATR*atr : quote.ask+InpTrailATR*atr;
         candidate=buy ? MathMax(candidate,trail) : MathMin(candidate,trail);
      }
      candidate=buy ? BGFloorPrice(MathMin(candidate,quote.bid-clearance),g_tickSize,g_digits)
                    : BGCeilPrice(MathMax(candidate,quote.ask+clearance),g_tickSize,g_digits);
      // Do not loosen a stop, even when the broker's minimum distance expands.
      bool improves=buy ? candidate>sl+g_tickSize : candidate<sl-g_tickSize;
      if(candidate>0.0 && improves)
         if(!g_trade.PositionModify(ticket,candidate,tp) || !AcceptedResult())
            PrintTradeFailure("Stop modification");
   }
}

bool EntryPreflight(const datetime now)
{
   if(g_dayLocked || g_campaignLocked || g_protectiveExitRequired || !g_storageOK)
   { g_state="Persistent equity/storage guard; entries blocked"; return false; }
   if(!TradingPermission()) { g_state="Algo trading/account permission disabled"; return false; }
   if(!SessionOpen(now)) { g_state="Outside broker-server session"; return false; }
   if(HasSymbolExposure()) { g_state="Existing gold position/order; no new entry"; return false; }
   RefreshDailyEntries(now);
   if(g_tradesToday>=InpMaxTradesPerDay) { g_state="Daily entry limit reached"; return false; }
   if(g_lastEntry>0 && now-g_lastEntry<InpCooldownMinutes*60)
   { g_state="Entry cooldown"; return false; }
   if(NewsBlocked(now)) return false;
   return true;
}

bool OpenFromRetest(const MqlRates &bar,const double atr,const int direction,const double level)
{
   MqlTick quote;
   if(!SymbolInfoTick(g_symbol,quote) || quote.bid<=0.0 || quote.ask<=0.0 ||
      TimeCurrent()-quote.time>30) { g_state="Quote unavailable/stale"; return false; }
   double spread=quote.ask-quote.bid;
   if(spread<0.0 || spread>InpMaxSpreadPrice || spread>InpMaxSpreadATR*atr)
   { g_state="Spread too wide for entry"; return false; }
   bool buy=(direction==1);
   ENUM_ORDER_TYPE side=buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   long trade_mode=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_MODE);
   if(trade_mode==SYMBOL_TRADE_MODE_DISABLED || trade_mode==SYMBOL_TRADE_MODE_CLOSEONLY ||
      (buy && trade_mode==SYMBOL_TRADE_MODE_SHORTONLY) ||
      (!buy && trade_mode==SYMBOL_TRADE_MODE_LONGONLY))
   { g_state="Broker symbol does not allow this entry direction"; return false; }
   double entry=buy ? quote.ask : quote.bid;
   if(!BGEntryNotChasing(direction,entry,bar.close,level,atr,
                         InpMaxEntryMoveATR,InpMaxEntryExtensionATR))
   { g_state="Entry moved too far from the retest"; return false; }
   double clearance=(double)SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL)*g_point+2.0*g_tickSize;
   double sl,tp;
   if(buy)
   {
      double structure=MathMin(bar.low,level-0.25*atr);
      sl=BGFloorPrice(MathMin(MathMin(entry-InpStopATR*atr,structure),quote.bid-clearance),g_tickSize,g_digits);
      tp=BGCeilPrice(entry+(entry-sl)*InpRewardRisk,g_tickSize,g_digits);
   }
   else
   {
      double structure=MathMax(bar.high,level+0.25*atr);
      sl=BGCeilPrice(MathMax(MathMax(entry+InpStopATR*atr,structure),quote.ask+clearance),g_tickSize,g_digits);
      tp=BGFloorPrice(entry-(sl-entry)*InpRewardRisk,g_tickSize,g_digits);
   }
   if(sl<=0.0 || tp<=0.0 || MathAbs(entry-sl)>InpMaxStopATR*atr)
   { g_state="Required stop is invalid or too wide"; return false; }
   double budget=RiskBudget();
   double minimum=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);
   double worst_entry=buy ? entry+InpSlippagePrice : entry-InpSlippagePrice;
   double loss=0.0;
   if(budget<=0.0 || minimum<=0.0 ||
      !OrderCalcProfit(side,g_symbol,minimum,worst_entry,sl,loss) || loss>=0.0)
   { g_state="Cannot calculate stop risk in account currency"; return false; }
   double loss_per_lot=MathAbs(loss)/minimum+InpCommissionPerLotRoundTrip;
   double lots=BGFloorLots(budget/loss_per_lot,minimum,maximum,step);
   if(lots<=0.0) { g_state="Minimum lot would exceed the risk budget"; return false; }
   double estimated=0.0,margin=0.0;
   if(!OrderCalcProfit(side,g_symbol,lots,worst_entry,sl,estimated) ||
      MathAbs(estimated)+lots*InpCommissionPerLotRoundTrip>budget+1e-6 ||
      !OrderCalcMargin(side,g_symbol,lots,entry,margin) ||
      margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)*0.50)
   { g_state="Final risk/margin check rejected the order"; return false; }
   bool sent=buy ? g_trade.Buy(lots,g_symbol,0.0,sl,tp,"BhavyaGold v1")
                 : g_trade.Sell(lots,g_symbol,0.0,sl,tp,"BhavyaGold v1");
   if(!sent || !AcceptedResult())
   { PrintTradeFailure("Entry"); g_state="Broker rejected entry; see Experts log"; return false; }
   g_entryBudget=budget; SaveKey(".budget",budget);
   g_lastEntry=TimeCurrent();
   PrintFormat("Entry accepted: direction=%d lots=%.8f target risk=%.2f %s SL=%.*f TP=%.*f",
               direction,lots,budget,AccountInfoString(ACCOUNT_CURRENCY),g_digits,sl,g_digits,tp);
   if(ProtectOwnPositions()) g_state="Retest order accepted";
   return true;
}

void ProcessClosedBar(const datetime now)
{
   if(!EntryPreflight(now)) { ResetPending(); return; }
   MqlRates bars[];
   ArraySetAsSeries(bars,true);
   if(CopyRates(g_symbol,PERIOD_M5,0,InpBoxBars+3,bars)<InpBoxBars+3)
   { g_state="Loading M5 history"; return; }
   double atr=0.0;
   int trend=0;
   if(!ReadIndicator(g_atr,0,1,atr) || atr<=0.0 || !TrendDirection(trend))
   { g_state="Loading closed-bar indicator history"; return; }
   g_lastATR=atr;
   if(g_pendingDirection!=0)
   {
      bool expired=(bars[1].time-g_breakoutBar)>InpRetestBars*PeriodSeconds(PERIOD_M5);
      if(expired || trend!=g_pendingDirection ||
         BGInvalidRetest(g_pendingDirection,bars[1].close,g_pendingLevel,atr,InpRetestPenetrationATR))
         ResetPending();
      else
      {
         g_state="Breakout armed; waiting for a later closed-bar retest";
         if(bars[1].time>g_breakoutBar &&
            BGIsRetest(g_pendingDirection,bars[1].open,bars[1].high,bars[1].low,
                       bars[1].close,g_pendingLevel,atr,InpRetestTouchATR,
                       InpRetestPenetrationATR,InpRetestCloseBufferATR,InpMaxSignalRangeATR))
         {
            OpenFromRetest(bars[1],atr,g_pendingDirection,g_pendingLevel);
            ResetPending(); // One attempt per setup, including a rejected order.
         }
         return;
      }
   }
   if(trend==0) { g_state="Trend filters do not agree"; return; }
   double high=bars[2].high,low=bars[2].low;
   // Box uses bars 2..N+1. The signal (bar 1) and open bar 0 cannot enter the box.
   for(int i=3;i<=InpBoxBars+1;i++) { high=MathMax(high,bars[i].high); low=MathMin(low,bars[i].low); }
   int direction=BGDetectBreakout(trend,bars[1].open,bars[1].high,bars[1].low,bars[1].close,
                  high,low,atr,InpMinBoxATR,InpMaxBoxATR,InpBreakoutBufferATR,
                  InpBreakoutMaxExtensionATR,InpMinBodyATR,InpMaxSignalRangeATR);
   if(direction!=0)
   {
      g_pendingDirection=direction;
      g_pendingLevel=(direction==1 ? high : low);
      g_breakoutBar=bars[1].time;
      g_state="Breakout armed; awaiting retest";
   }
   else g_state="Waiting for a valid box breakout";
}

void WriteEquity()
{
   if(g_equityFile==INVALID_HANDLE) return;
   FileWrite(g_equityFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),8),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),8));
   FileFlush(g_equityFile);
}

struct TradeRecord
{
   ulong id;
   datetime entry_time,exit_time;
   double entry_volume,exit_volume,entry_weight,exit_weight,profit,commission,swap,fees;
   string side,reason;
   bool contaminated;
};

int FindRecord(TradeRecord &records[],const ulong id)
{
   for(int i=0;i<ArraySize(records);i++) if(records[i].id==id) return i;
   return -1;
}

void ExportClosedTrades()
{
   if(!InpExportResults || MQLInfoInteger(MQL_OPTIMIZATION) || g_exportStem=="") return;
   if(!HistorySelect(0,TimeCurrent())) { Print("Trade export: history selection failed"); return; }
   TradeRecord records[];
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=g_symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic ||
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
      ulong id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      if(FindRecord(records,id)>=0) continue;
      int index=ArraySize(records);
      ArrayResize(records,index+1);
      ZeroMemory(records[index]); records[index].id=id;
   }
   for(int i=0;i<total;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || HistoryDealGetString(deal,DEAL_SYMBOL)!=g_symbol) continue;
      int k=FindRecord(records,(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID));
      if(k<0) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      datetime when=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      double volume=HistoryDealGetDouble(deal,DEAL_VOLUME),price=HistoryDealGetDouble(deal,DEAL_PRICE);
      records[k].profit+=HistoryDealGetDouble(deal,DEAL_PROFIT);
      records[k].commission+=HistoryDealGetDouble(deal,DEAL_COMMISSION);
      records[k].swap+=HistoryDealGetDouble(deal,DEAL_SWAP);
      records[k].fees+=HistoryDealGetDouble(deal,DEAL_FEE);
      if(entry==DEAL_ENTRY_IN)
      {
         if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) records[k].contaminated=true;
         if(records[k].entry_time==0 || when<records[k].entry_time) records[k].entry_time=when;
         records[k].entry_volume+=volume; records[k].entry_weight+=price*volume;
         records[k].side=type==DEAL_TYPE_BUY ? "BUY" : "SELL";
      }
      else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         if(when>records[k].exit_time) records[k].exit_time=when;
         records[k].exit_volume+=volume; records[k].exit_weight+=price*volume;
         records[k].reason=EnumToString((ENUM_DEAL_REASON)HistoryDealGetInteger(deal,DEAL_REASON));
      }
      else records[k].contaminated=true; // Reversals/mixed ownership are outside this strategy.
   }
   string filename=g_exportStem+"_trades.csv";
   int file=FileOpen(filename,FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',',CP_UTF8);
   if(file==INVALID_HANDLE) { Print("Could not open trade export. Error ",GetLastError()); return; }
   FileWrite(file,"position_id","entry_time","exit_time","side","volume","entry_price",
             "exit_price","net_profit","commission","swap","fees","exit_reason");
   int written=0;
   for(int k=0;k<ArraySize(records);k++)
   {
      if(records[k].contaminated || records[k].entry_volume<=0.0 || records[k].exit_time==0 ||
         records[k].exit_volume<records[k].entry_volume-1e-8) continue;
      double net=records[k].profit+records[k].commission+records[k].swap+records[k].fees;
      FileWrite(file,(string)records[k].id,TimeToString(records[k].entry_time,TIME_DATE|TIME_SECONDS),
         TimeToString(records[k].exit_time,TIME_DATE|TIME_SECONDS),records[k].side,
         DoubleToString(records[k].entry_volume,8),
         DoubleToString(records[k].entry_weight/records[k].entry_volume,g_digits),
         DoubleToString(records[k].exit_weight/records[k].exit_volume,g_digits),
         DoubleToString(net,8),DoubleToString(records[k].commission,8),
         DoubleToString(records[k].swap,8),DoubleToString(records[k].fees,8),records[k].reason);
      written++;
   }
   FileClose(file);
   Print("Exported ",written," completed positions to ",TerminalInfoString(TERMINAL_COMMONDATA_PATH),"\\Files\\",filename);
}

void Dashboard()
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double daily=g_dayStart>0.0 ? 100.0*(equity/g_dayStart-1.0) : 0.0;
   double dd=g_campaignPeak>0.0 ? 100.0*(g_campaignPeak-equity)/g_campaignPeak : 0.0;
   Comment("BhavyaGold XAUUSD v1 | M5 breakout + retest\n",g_state,
           "\nRisk target: ",DoubleToString(InpRiskPercent,2),"% | Entries: ",g_tradesToday,"/",InpMaxTradesPerDay,
           "\nObserved daily equity change: ",DoubleToString(daily,2),"% | Campaign peak DD: ",DoubleToString(dd,2),"%",
           "\nDaily lock: ",(g_dayLocked ? "YES" : "no")," | Campaign lock: ",(g_campaignLocked ? "YES" : "no"),
           "\nAll session/news timestamps are BROKER SERVER TIME.");
}

bool ValidInputs()
{
   return InpMagic>0 && InpRiskPercent>0.0 && InpRiskPercent<=2.0 &&
      InpDailyLossPercent>0.0 && InpDailyLossPercent<100.0 &&
      InpDailyPeakLossPercent>0.0 && InpDailyPeakLossPercent<100.0 &&
      InpOverallPeakLossPercent>0.0 && InpOverallPeakLossPercent<100.0 &&
      InpMaxTradesPerDay>=1 && InpCooldownMinutes>=0 && InpCommissionPerLotRoundTrip>=0.0 &&
      InpH1FastEMA>1 && InpH1SlowEMA>InpH1FastEMA && InpADXPeriod>1 && InpMinADX>=0.0 &&
      InpD1FastEMA>1 && InpD1SlowEMA>InpD1FastEMA && InpATRPeriod>1 &&
      InpBoxBars>=3 && InpBoxBars<=500 && InpMinBoxATR>0.0 && InpMaxBoxATR>InpMinBoxATR &&
      InpBreakoutBufferATR>=0.0 && InpBreakoutMaxExtensionATR>InpBreakoutBufferATR &&
      InpMinBodyATR>=0.0 && InpMaxSignalRangeATR>0.0 && InpRetestBars>=1 &&
      InpRetestTouchATR>=0.0 && InpRetestPenetrationATR>=0.0 && InpRetestCloseBufferATR>=0.0 &&
      InpMaxEntryMoveATR>=0.0 && InpMaxEntryExtensionATR>0.0 &&
      InpStopATR>0.0 && InpMaxStopATR>=InpStopATR && InpRewardRisk>=1.0 &&
      InpBreakEvenAtR>0.0 && InpBreakEvenLockR>=0.0 && InpBreakEvenLockR<InpBreakEvenAtR &&
      InpTrailStartR>0.0 && InpTrailATR>0.0 && InpMaxHoldMinutes>=5 &&
      InpSessionStartHour>=0 && InpSessionStartHour<=23 &&
      InpSessionEndHour>=0 && InpSessionEndHour<=23 && InpFridayStopHour>=0 && InpFridayStopHour<=23 &&
      InpMaxSpreadPrice>0.0 && InpMaxSpreadATR>0.0 && InpSlippagePrice>=0.0 &&
      InpNewsMinutesBefore>=0 && InpNewsMinutesAfter>=0;
}

int OnInit()
{
   g_tester=(bool)MQLInfoInteger(MQL_TESTER);
   g_symbol=_Symbol;
   string name=g_symbol;
   StringToUpper(name);
   if(StringFind(name,"XAUUSD")!=0 && StringFind(name,"GOLD")!=0)
   { Print("Attach this EA to your broker's XAUUSD/GOLD chart."); return INIT_FAILED; }
   if(!g_tester && AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL && !InpAllowRealAccount)
   { Print("Real-account trading is disabled. Use a demo account or Strategy Tester first."); return INIT_FAILED; }
   if(!ValidInputs()) { Print("Invalid input configuration"); return INIT_PARAMETERS_INCORRECT; }
   g_point=SymbolInfoDouble(g_symbol,SYMBOL_POINT);
   g_tickSize=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   g_digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   if(g_point<=0.0 || g_tickSize<=0.0) { Print("Missing broker point/tick size"); return INIT_FAILED; }
   long order_mode=SymbolInfoInteger(g_symbol,SYMBOL_ORDER_MODE);
   if((order_mode&SYMBOL_ORDER_MARKET)==0 || (order_mode&SYMBOL_ORDER_SL)==0 || (order_mode&SYMBOL_ORDER_TP)==0)
   { Print("This symbol must support market orders, stop loss, and take profit."); return INIT_FAILED; }
   string identity=AccountInfoString(ACCOUNT_SERVER)+"|"+g_symbol+"|"+(string)InpMagic;
   g_key="BG1."+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"."+(string)HashText(identity);
   g_leaseKey=g_key+".lease";
   if(!AcquireLease()) { Print("Another instance is active, or lease creation failed. Use one chart per symbol/magic."); return INIT_FAILED; }
   if(!LoadRisk()) { Print("Could not initialize risk state"); return INIT_FAILED; }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetAsyncMode(false);
   g_trade.SetDeviationInPoints((ulong)MathCeil(InpSlippagePrice/g_point));
   if(!g_trade.SetTypeFillingBySymbol(g_symbol)) { Print("Unsupported filling policy"); return INIT_FAILED; }
   g_atr=iATR(g_symbol,PERIOD_M5,InpATRPeriod);
   g_h1Fast=iMA(g_symbol,PERIOD_H1,InpH1FastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_h1Slow=iMA(g_symbol,PERIOD_H1,InpH1SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   g_adx=iADX(g_symbol,PERIOD_H1,InpADXPeriod);
   if(InpUseD1Filter)
   {
      g_d1Fast=iMA(g_symbol,PERIOD_D1,InpD1FastEMA,0,MODE_EMA,PRICE_CLOSE);
      g_d1Slow=iMA(g_symbol,PERIOD_D1,InpD1SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   }
   if(g_atr==INVALID_HANDLE || g_h1Fast==INVALID_HANDLE || g_h1Slow==INVALID_HANDLE ||
      g_adx==INVALID_HANDLE || (InpUseD1Filter && (g_d1Fast==INVALID_HANDLE || g_d1Slow==INVALID_HANDLE)))
   { Print("Indicator creation failed"); return INIT_FAILED; }
   if(!EventSetTimer(5)) { Print("Timer creation failed"); return INIT_FAILED; }
   g_lastBar=iTime(g_symbol,PERIOD_M5,0);
   RefreshDailyEntries(TimeCurrent());
   if(InpExportResults && !MQLInfoInteger(MQL_OPTIMIZATION))
   {
      g_exportStem=SafeName(InpExportPrefix)+"_"+SafeName(g_symbol)+"_"+
         (string)AccountInfoInteger(ACCOUNT_LOGIN)+"_"+(string)InpMagic+"_"+
         (string)(long)TimeCurrent()+"_"+(string)GetMicrosecondCount();
      g_equityFile=FileOpen(g_exportStem+"_equity.csv",FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',',CP_UTF8);
      if(g_equityFile!=INVALID_HANDLE) { FileWrite(g_equityFile,"timestamp","equity","balance"); WriteEquity(); }
      else Print("Equity export unavailable. Error ",GetLastError());
   }
   g_initialized=true;
   g_state="Ready; waiting for the next M5 candle to close";
   Print("BhavyaGold ready. Symbol=",g_symbol," currency=",AccountInfoString(ACCOUNT_CURRENCY),
         " contract=",SymbolInfoDouble(g_symbol,SYMBOL_TRADE_CONTRACT_SIZE),
         " volume min/step=",SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN),"/",SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP),
         " server time=",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)," risk-state prefix=",g_key);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(!g_initialized || !OwnLease()) return;
   datetime now=TimeCurrent();
   UpdateRisk(now);
   ManagePositions(now);
   datetime bar=iTime(g_symbol,PERIOD_M5,0);
   if(bar>0 && bar!=g_lastBar)
   {
      g_lastBar=bar; WriteEquity(); ProcessClosedBar(now);
   }
   Dashboard();
}

void OnTimer()
{
   if(!g_initialized) return;
   RenewLease();
   if(OwnLease()) Dashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(!g_initialized || !OwnLease()) return;
   if(transaction.type==TRADE_TRANSACTION_DEAL_ADD && transaction.symbol==g_symbol)
   { RefreshDailyEntries(TimeCurrent()); WriteEquity(); }
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_initialized && OwnLease())
   {
      WriteEquity(); ExportClosedTrades(); SaveRisk();
      if(!g_tester) GlobalVariablesFlush();
   }
   if(g_equityFile!=INVALID_HANDLE) { FileClose(g_equityFile); g_equityFile=INVALID_HANDLE; }
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   if(g_h1Fast!=INVALID_HANDLE) IndicatorRelease(g_h1Fast);
   if(g_h1Slow!=INVALID_HANDLE) IndicatorRelease(g_h1Slow);
   if(g_adx!=INVALID_HANDLE) IndicatorRelease(g_adx);
   if(g_d1Fast!=INVALID_HANDLE) IndicatorRelease(g_d1Fast);
   if(g_d1Slow!=INVALID_HANDLE) IndicatorRelease(g_d1Slow);
   ReleaseLease(); Comment("");
}
