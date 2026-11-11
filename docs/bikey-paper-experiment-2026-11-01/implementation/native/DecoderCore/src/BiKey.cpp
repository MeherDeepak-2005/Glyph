#include "../include/BiKey.hpp"
#include "../include/NeuralFst.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
namespace kb {
namespace {
constexpr double inf = std::numeric_limits<double>::infinity();
double gaussian(GridPoint p, GridPoint mean, double sigma) {
    auto x=p.x-mean.x, y=p.y-mean.y; return (x*x+y*y)/(2*sigma*sigma);
}
}
std::optional<std::uint8_t> biKeyOutput(std::uint8_t state, BiKey label) noexcept {
    if (state != label.left || !grid(label.key) || (label.left && !grid(label.left))) return {};
    return label.key;
}
double biKeyTapCost(BiKey label, std::uint8_t typed, std::optional<TouchOffset> tap, double sigma) noexcept {
    auto mean=grid(label.key), point=grid(typed);
    if (!mean || !point) return label.key==typed ? 0 : 3;
    if (!(sigma>0) || !std::isfinite(sigma)) return inf;
    if (tap && std::isfinite(tap->dx) && std::isfinite(tap->dy)) {point->x+=tap->dx;point->y+=tap->dy;}
    return gaussian(*point,*mean,sigma);
}
double biKeyLiteralCost(std::string_view word, std::span<const std::optional<TouchOffset>> taps, double sigma) {
    double total=0;std::uint8_t left=0;
    for(std::size_t j=0;j<word.size();++j){auto key=std::uint8_t(word[j]);total+=biKeyTapCost({left,key},key,taps.size()==word.size()?taps[j]:std::nullopt,sigma);left=key;}
    return total;
}
double biKeyWordCost(std::string_view candidate,std::string_view typed,
        std::span<const std::optional<TouchOffset>> taps,double sigma,bool raw) {
    std::vector<double> before(typed.size()+1),previous(typed.size()+1),current(typed.size()+1);
    for(std::size_t j=1;j<=typed.size();++j)previous[j]=previous[j-1]+insertionCost;
    for(std::size_t i=1;i<=candidate.size();++i){
        std::uint8_t key=std::uint8_t(candidate[i-1]),left=i>1?std::uint8_t(candidate[i-2]):0;
        current[0]=previous[0]+(raw?deletionCost:deletionCostAt(key,left,0));
        for(std::size_t j=1;j<=typed.size();++j){
            std::uint8_t t=std::uint8_t(typed[j-1]),pt=j>1?std::uint8_t(typed[j-2]):0;
            auto tap=taps.size()==typed.size()?taps[j-1]:std::nullopt;
            current[j]=std::min({previous[j-1]+biKeyTapCost({std::uint8_t(left),key},t,tap,sigma),
                previous[j]+(raw?deletionCost:deletionCostAt(key,left,t)),
                current[j-1]+(raw?insertionCost:insertionCostAt(t,pt,key))});
            if(i>1&&j>1&&candidate[i-1]==typed[j-2]&&candidate[i-2]==typed[j-1]) {
                auto first=taps.size()==typed.size()?taps[j-2]:std::nullopt;
                auto prior=i>2?std::uint8_t(candidate[i-3]):0;
                current[j]=std::min(current[j],before[j-2]+transpositionCost+
                    biKeyTapCost({std::uint8_t(left),key},std::uint8_t(typed[j-2]),first,sigma)+
                    biKeyTapCost({std::uint8_t(prior),std::uint8_t(left)},t,tap,sigma));
            }
        }
        before.swap(previous);previous.swap(current);
    }
    return previous.back();
}
std::vector<RankedRow> decodeBiKeyGesture(SearchGraph& graph,std::span<const Point> raw,
        double sigma,double beam,std::size_t width,double channelWeight,const std::function<bool()>& cancel) {
    if(raw.size()<2||!width||!(sigma>0)||!std::isfinite(sigma))return {};
    for(auto p:raw)if(!std::isfinite(p.x)||!std::isfinite(p.y))return {};
    auto points=resample(raw,0.5);const auto& lex=graph.lexicon();
    struct Token {std::uint32_t node;bool moving;double cost,upper;};
    std::vector<Token> active;
    auto keyCost=[&](std::uint32_t node,Point p){auto g=grid(lex.nodes[node].label);return g?gaussian({p.x,p.y},*g,sigma):inf;};
    auto segment=[&](std::uint32_t node,Point p,Point previous){
        auto a=grid(lex.nodes[lex.parent[node]].label),b=grid(lex.nodes[node].label);if(!a||!b)return inf;
        auto dx=b->x-a->x,dy=b->y-a->y,length=dx*dx+dy*dy;
        if(length<1e-12)return keyCost(node,p);
        auto progress=[&](Point q){return ((q.x-a->x)*dx+(q.y-a->y)*dy)/length;};
        auto t=std::clamp(progress(p),0.0,1.0),back=std::max(0.0,progress(previous)-progress(p));
        return gaussian({p.x,p.y},{a->x+t*dx,a->y+t*dy},sigma)+back*back*length/(2*sigma*sigma);
    };
    for(std::size_t frame=0;frame<points.size();++frame){
        if(cancel&&cancel())return {};
        auto p=points[frame];std::vector<Token> next;
        auto add=[&](std::uint32_t node,bool moving,double cost){auto upper=graph.lookahead(0,node)-channelWeight*cost;if(std::isfinite(upper))next.push_back({node,moving,cost,upper});};
        if(!frame){auto n=lex.nodes[0];for(auto c=n.firstChild;c<n.firstChild+n.childCount;++c)add(c,false,keyCost(c,p));}
        else for(auto t:active){
            // Endpoint b holds at b; transition a_b holds along the a-to-b segment.
            add(t.node,t.moving,t.cost+(t.moving?segment(t.node,p,points[frame-1]):keyCost(t.node,p)));
            if(t.moving)add(t.node,false,t.cost+keyCost(t.node,p));
            // Leaving a_b emits b, then starts b_c. This permits the singleton b
            // frame to be absent, as in Figure 1; no zero-input lexical chains.
            auto n=lex.nodes[t.node];
            for(auto c=n.firstChild;c<n.firstChild+n.childCount;++c){
                if(lex.nodes[c].label==apostrophe)continue;
                if(!biKeyOutput(n.label,{n.label,lex.nodes[c].label}))continue;
                add(c,true,t.cost+segment(c,p,points[frame-1]));
                add(c,false,t.cost+keyCost(c,p));
            }
        }
        // Recombine equivalent C o L states before the global beam limit.
        std::sort(next.begin(),next.end(),[](auto a,auto b){return std::tie(a.node,a.moving,a.cost)<std::tie(b.node,b.moving,b.cost);});
        next.erase(std::unique(next.begin(),next.end(),[](auto a,auto b){return a.node==b.node&&a.moving==b.moving;}),next.end());
        std::sort(next.begin(),next.end(),[](auto a,auto b){return a.upper==b.upper?std::tie(a.node,a.moving)<std::tie(b.node,b.moving):a.upper>b.upper;});
        if(!next.empty()){auto floor=next.front().upper-beam;std::erase_if(next,[&](auto t){return t.upper<floor;});}
        if(next.size()>width)next.resize(width);active=std::move(next);
    }
    std::vector<RankedRow> out;
    for(auto t:active){if(t.moving)continue;auto word=lex.nodes[t.node].wordID;if(!word||lex.packed.blocked(std::uint32_t(*word)))continue;
        std::string text(lex.packed.word(*word));auto prior=graph.wordScore(0,std::uint32_t(*word));
        out.push_back({{text,t.cost,0},text,0,prior,prior-channelWeight*t.cost,{}});
    }
    std::sort(out.begin(),out.end(),[](const auto&a,const auto&b){return a.score==b.score?a.key<b.key:a.score>b.score;});
    return out;
}
}
