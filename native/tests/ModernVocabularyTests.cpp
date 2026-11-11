#include "Engine.hpp"
#include "DictionaryDigest.hpp"
#include "Safety.hpp"
#include <cassert>
#include <fstream>
#include <sstream>
#include <iostream>
using namespace kb;
static std::string read(const std::string& p){std::ifstream f(p,std::ios::binary);std::ostringstream o;o<<f.rdbuf();return o.str();}
static std::span<const std::byte> bytes(const std::string& s){return {reinterpret_cast<const std::byte*>(s.data()),s.size()};}
int main(int argc,char** argv){
 assert(argc==5);
 auto data=read(argv[1]),sidecar=read(argv[2]),modelData=read(argv[3]),safety=read(argv[4]);
 assert(!data.empty()&&!sidecar.empty()&&!modelData.empty());
 auto digest=dictionarySHA256(bytes("abc"));
 constexpr unsigned char expected[]{0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
 for(int i=0;i<32;++i)assert(digest[i]==std::byte(expected[i]));
 for(auto at:{0u,8u,12u,24u,56u,60u}){
  auto bad=sidecar;bad[at]^=char(0xff);PackedLexicon invalid(bytes(data));
  assert(!invalid.installModern(bytes(bad))&&!invalid.hasModern());
 }
 for(auto length:{0u,8u,55u,100u}){PackedLexicon invalid(bytes(data));assert(!invalid.installModern(bytes(sidecar).first(length)));}
 auto reader=std::make_shared<PackedLexicon>(bytes(data));assert(reader->installModern(bytes(sidecar)));
 assert(!reader->installModern(bytes(sidecar)));
 assert(reader->preserves("rizz")&&reader->preserves("pookie")&&!reader->allowsCorrection("hello rizz"));
 for(auto word:{"ate","cooked","based","mid","slay","aura"})assert(!reader->preserves(word)&&reader->allowsCorrection(word));
 auto model=NeuralWordModel::load(bytes(modelData));std::size_t checked=0;
 for(bool raw:{false,true})for(bool neural:{false,true}){
  EngineOptions options;options.raw=raw;auto engine=std::make_shared<Engine>(reader,options,nullptr,neural?model:nullptr);
  auto state=engine->createState();state->setSafety(parseSafetyPenalties(safety));auto session=engine->createSession();
  auto decode=[&](std::string text,std::vector<std::string> ctx={}) {
   DecodeInput in;in.word=text;in.normalized=text;in.context=std::move(ctx);in.modelTier=neural?"nss":"ngram";
   in.identity={1,1,1,++checked,1,0,0};return session->decode(in,state->view());
  };
  for(std::uint32_t id=0;id<reader->wordCount();++id){
   std::string word(reader->word(id));if(!reader->preserves(word))continue;
   auto out=decode(word,{"please","send"});assert(!out.correction.word&&out.suggestions.front()==word);
  }
  for(auto word:{"pook","pooki","poo","pook","pookie"})assert(decode(word).status==EngineStatus::ok);
  state->apply({UserEventKind::reset,"",{},1,true});session->memoryPressure();assert(!decode("delulu").correction.word);
  auto next=decode("",{"that's","no"});assert(std::find(next.suggestions.begin(),next.suggestions.end(),"cap")!=next.suggestions.end());
  auto prefix=decode("pook");assert(std::find(prefix.suggestions.begin(),prefix.suggestions.end(),"pookie")!=prefix.suggestions.end());
  for(auto word:{"risk","rich","best","beast","pocket","cooking","said","this","miss"}){
   auto out=decode(word);assert(!out.correction.word||reader->allowsCorrection(*out.correction.word));
  }
  CancellationToken token;token.cancel();DecodeInput in;in.word=in.normalized="rizz";
  assert(session->decode(in,state->view(),&token).status==EngineStatus::cancelled);
 }

 {
  EngineOptions options; options.nssOnly=true;
  auto strict=std::make_shared<Engine>(reader,options,nullptr,model);
  auto bare=std::make_shared<Engine>(std::make_shared<PackedLexicon>(bytes(data)),options,nullptr,model);
  auto state=strict->createState(),plain=bare->createState();
  for(auto text:{"","pook"}) {
   DecodeInput in;in.word=in.normalized=text;in.modelTier="nss";in.context={"that's","no"};
   auto a=strict->createSession()->decode(in,state->view());
   auto b=bare->createSession()->decode(in,plain->view());
   assert(a.suggestions==b.suggestions); // Sidecar context/prefix boosts cannot enter NSS-only.
  }
  for(std::uint32_t id=0;id<reader->wordCount();++id) {
   std::string word(reader->word(id));if(!reader->preserves(word))continue;
   DecodeInput in;in.word=in.normalized=word;in.modelTier="nss";
   auto out=strict->createSession()->decode(in,state->view());
   assert(!out.correction.word&&out.suggestions.front()==word);++checked;
  }
 }
 auto blocked=std::make_shared<PackedLexicon>(bytes(data));assert(blocked->installModern(bytes(sidecar)));
 std::vector<std::string> terms{"pookie"};blocked->installBlocked(terms);
 std::vector<std::string> ctx{"hey"},old{"hello","there"};auto suggestions=blocked->modernSuggestions("",ctx,old);
 assert(std::find(suggestions.begin(),suggestions.end(),"pookie")==suggestions.end());
 std::cout<<"modern vocabulary: "<<checked<<" decode checks passed\n";
}
