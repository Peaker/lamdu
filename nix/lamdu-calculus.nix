{ mkDerivation, base, base-compat, base16-bytestring, binary
, bytestring, constraints, containers, deepseq, fetchFromGitHub
, generic-data, hashable, lattices, lens, monad-st, mtl, pretty
, QuickCheck, hypertypes, transformers, lib, HUnit, test-framework, test-framework-hunit
}:
mkDerivation {
  pname = "lamdu-calculus";
  version = "0.1.0.0";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "lamdu-calculus";
    sha256 = "1klgidkn28lgdjrz59lfs8g8rqqgs5iq52p3spvsz259z7fn3nlf";
    rev = "21332a4c1576ad028bbb693b23e8943089256ef8";
  };
  libraryHaskellDepends = [
    base base-compat base16-bytestring binary bytestring constraints containers
    deepseq generic-data hashable lattices lens monad-st mtl pretty QuickCheck hypertypes transformers
    HUnit test-framework test-framework-hunit
  ];
  homepage = "https://github.com/lamdu/lamdu-calculus.git#readme";
  description = "The Lamdu Calculus programming language";
  license = lib.licenses.bsd3;
}
