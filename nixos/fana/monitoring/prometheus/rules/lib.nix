{ lib }:
rec {
  mkAlert =
    {
      name,
      expr,
      for ? null,
      severity,
      category,
      summary,
      description,
    }:
    {
      alert = name;
      inherit expr;
      labels = { inherit category severity; };
      annotations = { inherit description summary; };
    }
    // lib.optionalAttrs (for != null) { inherit for; };

  mkScrapeDown =
    {
      name,
      selector,
      for,
      severity ? "warning",
      category,
      summary,
      description,
    }:
    mkAlert {
      inherit
        category
        description
        for
        name
        severity
        summary
        ;
      expr = "${selector} < 1";
    };

  mkGroup =
    {
      name,
      interval ? "30s",
      rules,
    }:
    {
      inherit interval name rules;
    };
}
