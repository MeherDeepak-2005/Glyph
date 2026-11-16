#define main kbIOSBenchMain
#include "../tools/evaluation/autocorrect/IOSBench.cpp"
#undef main

extern "C" int kb_ios_bench(int argc, char** argv) { return kbIOSBenchMain(argc, argv); }
