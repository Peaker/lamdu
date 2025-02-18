{ mkDerivation, base, bindings-GLFW, deepseq
, HUnit, test-framework, test-framework-hunit
, fetchFromGitHub, stdenv, lib
}:
mkDerivation {
  pname = "GLFW-b";
  version = "3.2.1.2";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "GLFW-b";
    sha256 = "1ac7wp9p8swaj7n3gva29d0g7r4vgp0k9n7m6gs45b6i35gf9gjf";
    rev = "04b0c6c36f351ce629af6bbe76ff440c40b3ff8c";
  };
  postPatch = ''
    rm Setup.hs
  '';
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [ base bindings-GLFW deepseq ];
  executableHaskellDepends = [
    base bindings-GLFW deepseq HUnit test-framework test-framework-hunit
  ];
  license = lib.licenses.bsd3;
}
