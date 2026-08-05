/* global window */

(() => {
  const platform = "arcade";
  const defaultCore = "mame2003_plus";
  const previousDefaultCore = "mame2003";
  const key = `player:${platform}:core`;
  const migrationKey = `player:${platform}:core-default:${defaultCore}`;

  try {
    const currentCore = window.localStorage.getItem(key);

    if (currentCore === null) {
      window.localStorage.setItem(key, defaultCore);
      window.localStorage.setItem(migrationKey, "true");
      return;
    }

    if (
      currentCore === previousDefaultCore &&
      window.localStorage.getItem(migrationKey) !== "true"
    ) {
      window.localStorage.setItem(key, defaultCore);
      window.localStorage.setItem(migrationKey, "true");
    }
  } catch {
    // Browser storage can be unavailable in restricted/private contexts.
  }
})();
