{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

buildGoModule rec {
  pname = "prometheus-paperless-exporter";
  version = "0.0.10";

  src = fetchFromGitHub {
    owner = "hansmi";
    repo = "prometheus-paperless-exporter";
    rev = "v${version}";
    hash = "sha256-lkbys21Cg2PKD7IvkC+6ZXMJrfsN4vzCA3s3/9up7Ao=";
  };

  vendorHash = "sha256-tcDvjvh8ZwxRfTD8/rZwNanIxqN7UMFd2p6F3Yid4iM=";

  meta = {
    description = "Paperless-ngx metrics for Prometheus";
    homepage = "https://github.com/hansmi/prometheus-paperless-exporter";
    changelog = "https://github.com/hansmi/prometheus-paperless-exporter/releases/tag/v${version}";
    license = lib.licenses.bsd3;
    mainProgram = "prometheus-paperless-exporter";
    platforms = lib.platforms.linux;
  };
}
