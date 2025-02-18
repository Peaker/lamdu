{ mkDerivation, fetchFromGitHub, lib
, base, text, binary
}:
mkDerivation {
  pname = "text-trie";
  version = "0.2.5.0";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "text-trie";
    sha256 = "0xssgc9533wxzxldxgn5lzcv84fn33n406ka112vgb8g88fgfa3q";
    rev = "2b4c94bccaa9c60f59ff06fad04d52b113a53ff2";
  };
  libraryHaskellDepends = [
    base text binary
  ];
  homepage = "https://github.com/lamdu/text-trie";
  description = "An efficient finite map from Text to values, based on bytestring-trie.";
  license = lib.licenses.bsd3;
}
