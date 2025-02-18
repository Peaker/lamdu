{ mkDerivation, base, bytestring, data-default, exceptions, filepath, resourcet, transformers
, fetchFromGitHub, hsc2hs, lib, rocksdb
}:
mkDerivation {
  pname = "rocksdb-haskell";
  version = "1.0.2";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "rocksdb-haskell";
    sha256 = "01l84fnbc8awx4ymq6y0ilf2b8ysfjj9r3sxx8fpy8189dd3cmpw";
    rev = "c0b13d11784fff618f6a459e1570bb0b369d2551";
  };
  postPatch = ''
    rm Setup.hs
  '';
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [
    base bytestring data-default exceptions filepath resourcet transformers
  ];
  librarySystemDepends = [ hsc2hs rocksdb ];
  license = lib.licenses.bsd3;
}
