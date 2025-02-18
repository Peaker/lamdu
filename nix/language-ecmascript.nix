{ mkDerivation, base, fetchFromGitHub, lib, which }:
mkDerivation {
  pname = "language-ecmascript";
  version = "0.19.1.0";
  src = fetchFromGitHub {
    owner = "jswebtools";
    repo = "language-ecmascript";
    rev = "a1e47e69e68f6f70f8eca40d28dd8b702262a123";
    sha256 = "0xaa0ly4jjslpahj12mvc0wghzfwggkllxfrpdf51f7m1yprbnav";
  };
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [ base ];
  extraLibraries = [ nodejs ];
  license = lib.licenses.bsd3;
}
