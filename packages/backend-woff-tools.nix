# sfnt2woff / woff2sfnt, Jonathan Kew's reference WOFF <-> sfnt converters.
# Required by the Penpot backend for font format conversion, but not packaged
# in nixpkgs. Upstream's page (people.mozilla.org/~jkew/woff) is offline, so
# this uses the source mirror several distributions rely on.
{
  lib,
  stdenv,
  fetchFromGitHub,
  zlib,
}:

stdenv.mkDerivation {
  pname = "woff-tools";
  version = "20091003";

  src = fetchFromGitHub {
    owner = "wget";
    repo = "woff-tools";
    rev = "20091003";
    hash = "sha256-GDF07R4dNfVz9S1bWkDndq4Zy916kkuaWu6nXYlZRkU=";
  };

  buildInputs = [ zlib ];

  installPhase = ''
    runHook preInstall

    install -Dm755 sfnt2woff $out/bin/sfnt2woff
    install -Dm755 woff2sfnt $out/bin/woff2sfnt
    install -Dm644 LICENSE $out/share/licenses/woff-tools/LICENSE

    runHook postInstall
  '';

  meta = {
    description = "Convert TrueType/OpenType (sfnt) fonts to WOFF format and back";
    homepage = "https://github.com/wget/woff-tools";
    # woff.c carries the classic Mozilla tri-license.
    license = with lib.licenses; [
      mpl11
      gpl2Plus
      lgpl21Plus
    ];
    platforms = lib.platforms.linux;
    mainProgram = "sfnt2woff";
  };
}
