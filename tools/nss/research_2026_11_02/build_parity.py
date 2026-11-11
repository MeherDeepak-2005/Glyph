import pathlib,re,subprocess
root=pathlib.Path('.');text=(root/'native/CMakeLists.txt').read_text();start=text.index('add_library(DecoderCore STATIC');files=[str(root/'native'/l.strip()) for l in text[start:text.index(')',start)].splitlines()[1:] if l.strip().endswith('.cpp')]
subprocess.run(['xcrun','clang++','-std=c++20','-O1','-I',str(root/'native/DecoderCore/include'),str(root/'native/tests/NeuralLanguageModelTests.cpp'),*files,'-o',str(root/'tools/.cache/dictionary-research-2026-11-02/neural-parity')],check=True)
print('PARITY HARNESS BUILT')
