#include <cmath>
#include <algorithm>
#include <cassert>
#include <iostream>
#include <random>

double MathFloor(double v) { return std::floor(v); }
double MathCeil(double v) { return std::ceil(v); }
double MathMin(double a,double b) { return std::min(a,b); }
double MathMax(double a,double b) { return std::max(a,b); }
double MathAbs(double v) { return std::abs(v); }
double NormalizeDouble(double v,int digits) {
    double scale=std::pow(10.0,digits); return std::round(v*scale)/scale;
}
// These are the production .mqh decisions, not a Python copy of their logic.
#include "../MQL5/Experts/BhavyaGold/GoldCore.mqh"

int main() {
    assert(BGFloorLots(0.009,0.01,100.0,0.01)==0.0);
    assert(std::abs(BGFloorLots(0.185,0.01,100.0,0.01)-0.18)<1e-10);
    assert(BGFloorLots(0.05,0.10,100.0,0.10)==0.0);
    assert(std::abs(BGFloorLots(2.0,0.01,0.25,0.01)-0.25)<1e-10);
    assert(BGFloorLots(0.10,0.01,100.0,0.0)==0.0);
    assert(std::abs(BGFloorLots(0.075,0.03,100.0,0.02)-0.07)<1e-10);
    assert(std::abs(BGRiskBudget(25000,0.25,24750)-62.5)<1e-10);
    assert(std::abs(BGRiskBudget(24760,0.25,24750)-9.0)<1e-10);
    assert(BGRiskBudget(24750,0.25,24750)==0.0);
    assert(BGRiskFloor(25000,25100,26000,1,1,5)==24849);
    assert(BGInSession(7,7,20) && BGInSession(19,7,20) && !BGInSession(20,7,20));
    assert(BGInSession(23,22,6) && BGInSession(2,22,6) && !BGInSession(12,22,6));
    assert(BGInSession(12,0,0) && !BGInSession(25,0,0));

    // Box 99..101, ATR 1: a properly bounded, directional breakout can arm.
    assert(BGDetectBreakout(1,100.9,101.5,100.8,101.3,101,99,1,1,4,.1,.8,.15,2.5)==1);
    assert(BGDetectBreakout(0,100.9,101.5,100.8,101.3,101,99,1,1,4,.1,.8,.15,2.5)==0);
    assert(BGDetectBreakout(1,100.9,102.2,100.8,102.0,101,99,1,1,4,.1,.8,.15,2.5)==0);
    assert(BGDetectBreakout(1,100.9,101.5,98.0,101.3,101,99,1,1,4,.1,.8,.15,2.5)==0);
    assert(BGDetectBreakout(-1,99.1,99.2,98.5,98.7,101,99,1,1,4,.1,.8,.15,2.5)==-1);
    assert(BGIsRetest(1,101.05,101.4,100.95,101.2,101,1,.25,.5,.05,2.5));
    assert(BGIsRetest(-1,98.95,99.05,98.6,98.8,99,1,.25,.5,.05,2.5));
    assert(!BGIsRetest(1,101.05,101.4,100.4,101.2,101,1,.25,.5,.05,2.5));
    assert(BGInvalidRetest(1,100.4,101,1,.5));
    assert(BGInvalidRetest(-1,99.6,99,1,.5));
    assert(BGEntryNotChasing(1,101.3,101.2,101,1,.35,.9));
    assert(!BGEntryNotChasing(1,101.7,101.2,101,1,.35,.9));
    assert(BGEntryNotChasing(-1,98.7,98.8,99,1,.35,.9));
    assert(!BGEntryNotChasing(-1,98.2,98.8,99,1,.35,.9));
    assert(!BGEntryNotChasing(1,100.9,101.2,101,1,.35,.9));

    std::mt19937_64 random(26100601);
    std::uniform_real_distribution<double> uniform(0.0,1.0);
    for(int i=0;i<100000;i++) {
        double budget=1.0+uniform(random)*10000;
        double loss_per_lot=1.0+uniform(random)*50000;
        double step=std::pow(10.0,-(1+i%3)), minimum=step;
        double desired=budget/loss_per_lot;
        double lots=BGFloorLots(desired,minimum,100.0,step);
        assert(lots==0.0 || lots>=minimum-1e-10);
        assert(lots<=desired+1e-9 && lots<=100.0+1e-9);
        assert(lots*loss_per_lot<=budget+1e-5);
        if(lots>0) assert(std::abs(lots/step-std::round(lots/step))<1e-6);
        double price=100.0+uniform(random)*10000.0;
        double tick=(i%2==0 ? 0.01 : 0.05);
        double floor=BGFloorPrice(price,tick,2),ceil=BGCeilPrice(price,tick,2);
        assert(floor<=price+1e-7 && ceil>=price-1e-7);
        assert(ceil-floor<=tick+1e-7);
        double equity=1000.0+uniform(random)*100000;
        double risk_floor=equity-(uniform(random)*1000);
        double target=BGRiskBudget(equity,.25,risk_floor);
        assert(target<=equity*.0025+1e-8);
        assert(target<=.90*(equity-risk_floor)+1e-8);
    }
    std::cout << "Core: deterministic signal/risk cases and 100,000 randomized invariant cases passed.\n";
}
