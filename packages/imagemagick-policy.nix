# Hardened ImageMagick policy shipped by the upstream images (resource caps
# and PS/EPS/PDF/XPS coders disabled); nixpkgs' default policy is
# unrestricted and the backend/exporter process user-controlled content.
{
  runCommand,
  penpot,
}:
runCommand "penpot-imagemagick-policy" { } ''
  install -Dm644 "${penpot}/docker/images/files/imagemagick-policy.xml" \
    "$out/etc/ImageMagick-7/policy.xml"
''
