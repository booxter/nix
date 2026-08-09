{ lib }:
{
  finalize =
    {
      facts,
      enrich ? (value: value),
      assertions ? (_: [ ]),
    }:
    let
      enriched = enrich facts;
    in
    lib.foldl' (
      result: check:
      assert lib.assertMsg check.assertion check.message;
      result
    ) enriched (assertions enriched);
}
