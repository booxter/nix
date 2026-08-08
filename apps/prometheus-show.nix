{
  appSpec,
  nixosConfigurations,
  pkgs,
}:
let
  inherit (pkgs) lib;
  prometheusHosts = lib.filterAttrs (
    _: host: host.config.host.observability.prometheus.enable or false
  ) nixosConfigurations;
  prometheusHostNames = builtins.attrNames prometheusHosts;
  prometheusHost =
    assert lib.assertMsg (
      builtins.length prometheusHostNames == 1
    ) "prometheus-show requires exactly one Prometheus host";
    prometheusHosts.${lib.head prometheusHostNames};
  defaultTo = fallback: value: if value == null then fallback else value;
  showValue = value: if value == null then "-" else toString value;
  rowFor = job: staticConfig: target: {
    job = job.job_name;
    scheme = showValue (defaultTo "http" (job.scheme or null));
    path = showValue (defaultTo "/metrics" (job.metrics_path or null));
    target = showValue target;
    instance = showValue (staticConfig.labels.instance or null);
    service = showValue (staticConfig.labels.service or null);
    component = showValue (staticConfig.labels.component or null);
    availability = showValue (
      staticConfig.labels.availability or (staticConfig.labels.scrape_expectation or null)
    );
    profile = showValue (staticConfig.labels.scrape_profile or null);
  };
  rows = lib.concatMap (
    job:
    lib.concatMap (staticConfig: map (rowFor job staticConfig) staticConfig.targets) (
      job.static_configs or [ ]
    )
  ) prometheusHost.config.services.prometheus.scrapeConfigs;
  columns = [
    {
      heading = "JOB";
      field = "job";
    }
    {
      heading = "TARGET";
      field = "target";
    }
    {
      heading = "SCHEME";
      field = "scheme";
    }
    {
      heading = "PATH";
      field = "path";
    }
    {
      heading = "INSTANCE";
      field = "instance";
    }
    {
      heading = "SERVICE";
      field = "service";
    }
    {
      heading = "COMPONENT";
      field = "component";
    }
    {
      heading = "AVAILABILITY";
      field = "availability";
    }
    {
      heading = "PROFILE";
      field = "profile";
    }
  ];
  widthFor =
    column:
    lib.foldl' lib.max (builtins.stringLength column.heading) (
      map (row: builtins.stringLength row.${column.field}) rows
    );
  columnsWithWidths = map (column: column // { width = widthFor column; }) columns;
  repeat = count: value: lib.concatStrings (lib.replicate count value);
  pad = width: value: value + repeat (width - builtins.stringLength value) " ";
  renderValues =
    values:
    lib.concatMapStringsSep "  " (column: pad column.width values.${column.field}) columnsWithWidths;
  headingValues = builtins.listToAttrs (
    map (column: {
      name = column.field;
      value = column.heading;
    }) columnsWithWidths
  );
  separator = lib.concatMapStringsSep "  " (column: repeat column.width "-") columnsWithWidths;
  table = lib.concatStringsSep "\n" (
    [
      (renderValues headingValues)
      separator
    ]
    ++ map renderValues rows
  );
  prometheusShow = pkgs.writeShellApplication {
    name = "prometheus-show";
    text = ''
      printf '%s\n' ${lib.escapeShellArg table}
    '';
  };
in
appSpec (lib.getExe prometheusShow) "Show evaluated Prometheus scrape targets and policy labels."
