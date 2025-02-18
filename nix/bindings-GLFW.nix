{ mkDerivation, base, bindings-DSL, fetchFromGitHub, hsc2hs, stdenv, libGL, libX11, libXi, libXrandr, libXxf86vm, libXcursor, libXinerama, libXext, lib }:
mkDerivation {
  pname = "bindings-GLFW";
  version = "3.2.1.2";
  src = fetchFromGitHub {
    owner = "lamdu";
    repo = "bindings-GLFW";
    sha256 = "1rza1vx7919czzc4g64xyhkj6jp78iqkkrj3sm8hzq0xmp8f8mmd";
    rev = "0f7b821b75cb620ccf8fbdda6f1f4912f049c551";
  };
  postPatch = ''
    rm Setup.hs
  '';
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [ base bindings-DSL ];
  librarySystemDepends =
      [ hsc2hs libGL libX11 libXi libXrandr libXxf86vm libXcursor libXinerama libXext
      ];
  license = lib.licenses.bsd3;
}
