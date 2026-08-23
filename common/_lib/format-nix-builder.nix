{ lib }:
builder:
let
  mandatoryFeatures = builder.mandatoryFeatures or [ ];
  publicHostKey = builder.publicHostKey or null;
  system = builder.system or null;
  formatList = values: if values == [ ] then "-" else lib.concatStringsSep "," values;
in
lib.concatMapStringsSep " " toString [
  "${lib.optionalString (builder.protocol != null) "${builder.protocol}://"}${
    lib.optionalString (builder.sshUser != null) "${builder.sshUser}@"
  }${builder.hostName}"
  (if system != null then system else formatList builder.systems)
  (if builder.sshKey != null then builder.sshKey else "-")
  builder.maxJobs
  builder.speedFactor
  (formatList (builder.supportedFeatures ++ mandatoryFeatures))
  (formatList mandatoryFeatures)
  (if publicHostKey != null then publicHostKey else "-")
]
