{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  hatchling,
  httpx,
  pillow,
  pypdfium2,
  pytestCheckHook,
  reportlab,
}:

buildPythonPackage {
  pname = "paperless-llm-ocr";
  version = "0.1.0-unstable-2026-10-27";
  pyproject = true;

  # No releases have been tagged yet. Track main until one is published.
  src = fetchFromGitHub {
    owner = "zhzy0077";
    repo = "paperless-llm-ocr";
    rev = "2f8746cdfda5de538583b4f5bdc8791716ec27e5";
    hash = "sha256-+ub440eGMtylsxkA94iREjuRLnXsD/n3aggxCqMAeYs=";
  };

  build-system = [ hatchling ];
  dependencies = [
    httpx
    pillow
    pypdfium2
    reportlab
  ];
  # nixpkgs provides reportlab 5; exercise archive generation with it below.
  pythonRelaxDeps = [ "reportlab" ];
  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "paperless_llm_ocr" ];

  meta = {
    description = "OpenAI-compatible vision OCR parser for Paperless-ngx";
    homepage = "https://github.com/zhzy0077/paperless-llm-ocr";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
