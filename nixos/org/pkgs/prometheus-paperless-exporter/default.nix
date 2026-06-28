{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

buildGoModule rec {
  pname = "prometheus-paperless-exporter";
  version = "0.0.9";

  src = fetchFromGitHub {
    owner = "hansmi";
    repo = "prometheus-paperless-exporter";
    rev = "v${version}";
    hash = "sha256-KY2PvIvmTaM/p4v3LScAG7Q1HmZG/afEmgvy1iSGHAU=";
  };

  vendorHash = "sha256-JDcGV11v2cNXaLhlcuJH0aM1v1hJADZbtZWZ9dPj894=";

  meta = {
    description = "Paperless-ngx metrics for Prometheus";
    homepage = "https://github.com/hansmi/prometheus-paperless-exporter";
    changelog = "https://github.com/hansmi/prometheus-paperless-exporter/releases/tag/v${version}";
    license = lib.licenses.bsd3;
    mainProgram = "prometheus-paperless-exporter";
    platforms = lib.platforms.linux;
  };
}
