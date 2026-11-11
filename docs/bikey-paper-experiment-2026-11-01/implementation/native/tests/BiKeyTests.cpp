#include "../DecoderCore/include/BiKey.hpp"
#include "../DecoderCore/include/Engine.hpp"
#include "MiniJson.hpp"
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
using namespace kb;
static std::string read(const char* p){std::ifstream f(p,std::ios::binary);assert(f);std::stringstream s;s<<f.rdbuf();return s.str();}
static std::vector<std::byte> bytes(const char*p){auto s=read(p);std::vector<std::byte>b(s.size());std::memcpy(b.data(),s.data(),s.size());return b;}
int main(int argc,char**argv){
 assert(argc==5);
 assert(biKeyOutput('a',{'a','b'})==std::optional<std::uint8_t>('b'));
 assert(!biKeyOutput('c',{'a','b'}));assert(!biKeyOutput('a',{'a',0}));
 assert(biKeyOutput(0,{0,'a'}));assert(biKeyOutput('a',{'a','a'}));
 assert(biKeyTapCost({'a','b'},'b',TouchOffset{0,0},.7)==0);
 assert(std::abs(biKeyTapCost({'a','b'},'b',TouchOffset{.4,.3},.7)-.25/.98)<1e-10);
 assert(!std::isfinite(biKeyTapCost({'a','b'},'b',{},0)));
 std::vector<std::optional<TouchOffset>> taps(3,TouchOffset{.2,.1});
 assert(std::abs(biKeyLiteralCost("cat",taps,.7)-3*.05/.98)<1e-10);
 assert(std::abs(biKeyWordCost("cat","cat",taps,.7)-biKeyLiteralCost("cat",taps,.7))<1e-10);
 assert(biKeyWordCost("cat","cta",{},.7)<=transpositionCost+1e-10);
 auto pack=bytes(argv[2]),modelBytes=bytes(argv[1]);auto lex=std::make_shared<PackedLexicon>(pack);auto model=NeuralWordModel::load(modelBytes);
 auto indexed=std::make_shared<NeuralLexicon>(*lex);NeuralFst graph(model,indexed);graph.update(std::vector<std::string>{"i","say"});
 NeuralFstSearch::Options opt{16,512,false,.7,4,true};NeuralFstSearch incremental(graph,opt);
 std::vector<RankedRow> old;
 for(auto p:{"h","he","hel","hell","hello"})old=incremental.decode(p,{});
 graph.update(std::vector<std::string>{"i","say"},true);NeuralFstSearch fresh(graph,opt);auto now=fresh.decode("hello",{});
 assert(old.size()==now.size());for(std::size_t i=0;i<now.size();++i){assert(old[i].key==now[i].key);assert(std::abs(old[i].score-now[i].score)<1e-8);}
 assert(fresh.decode("hello",{},[]{return true;}).empty());assert(fresh.decode("é",{}).empty());
 assert(decodeBiKeyGesture(graph,std::vector<Point>{{0,0},{NAN,0}},.7,16,512,4).empty());
 assert(decodeBiKeyGesture(graph,std::vector<Point>{{0,0},{1,0}},.7,16,512,4,[]{return true;}).empty());
 // All fixture gesture arms use the same lexicon, neural checkpoint and context.
 int mode=std::stoi(argv[4]);EngineOptions options;options.nssBiKey=(mode&1);options.nssPaperScoring=(mode&2);options.nssExact=!(mode&2);
 auto engine=std::make_shared<Engine>(lex,options,nullptr,model);auto state=engine->createState();auto session=engine->createSession();
 GlideLayout layout{{},1,1};for(auto row:{"qwertyuiop","asdfghjkl","zxcvbnm"})for(unsigned char c:std::string_view(row)){auto g=grid(c);layout.centers.push_back({c,{g->x,g->y}});}
 auto fixtures=json::parse(read(argv[3]));
 for(auto& f:fixtures.array()){
  std::vector<std::string> ctx;for(auto& c:f["context"].array())ctx.push_back(c.text());
  std::vector<Point> points;for(auto& p:f["points"].array())points.push_back({p.array()[0].number(),p.array()[1].number()});
  session->beginGlide(ctx);auto start=std::chrono::steady_clock::now();auto rows=session->updateGlide(points,layout,state->view(),{});
  auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  int rank=-1;for(std::size_t i=0;i<rows.size();++i)if(rows[i].key==f["word"].text())rank=int(i);
  std::cout<<f["id"].text()<<'\t'<<f["word"].text()<<'\t'<<f["noise"].number()<<'\t'<<rank<<'\t'<<ms;
  for(std::size_t i=0;i<std::min<std::size_t>(3,rows.size());++i)std::cout<<'\t'<<rows[i].key;
  std::cout<<'\n';
 }
 std::cerr<<"Bi-key consistency, Gaussian/literal parity, DP, incremental tap replay, malformed input and cancellation passed\n";
}
