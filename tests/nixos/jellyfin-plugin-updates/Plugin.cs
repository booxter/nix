using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace CatalogueFixture;

public sealed class Configuration : BasePluginConfiguration
{
    public string ManagedSetting { get; set; } = "default";
    public string UserSetting { get; set; } = "default";
}

public sealed class Plugin : BasePlugin<Configuration>
{
    public static Plugin Instance { get; private set; } = null!;

    public Plugin(IApplicationPaths paths, IXmlSerializer serializer)
        : base(paths, serializer)
    {
        Instance = this;
    }

    public override string Name => "Catalogue Fixture";
    public override Guid Id => new("6d033048-d833-4df8-bfb5-d7555d612737");
}

[ApiController]
[AllowAnonymous]
[Route("CatalogueFixture")]
public sealed class Controller : ControllerBase
{
    [HttpGet]
    public object Get()
    {
        var plugin = Plugin.Instance;

        return new
        {
            Version = plugin.Version.ToString(),
            plugin.Configuration.ManagedSetting,
            plugin.Configuration.UserSetting,
        };
    }
}
