from __future__ import annotations

from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, JsonValue, RootModel, StrictBool

NonNegativeInt = Annotated[int, Field(ge=0)]


class OidcSettings(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    active_auth_methods: tuple[str, ...] = Field(alias="authActiveAuthMethods")
    issuer_url: str = Field(alias="authOpenIDIssuerURL")
    authorization_url: str = Field(alias="authOpenIDAuthorizationURL")
    token_url: str = Field(alias="authOpenIDTokenURL")
    user_info_url: str = Field(alias="authOpenIDUserInfoURL")
    jwks_url: str = Field(alias="authOpenIDJwksURL")
    logout_url: str | None = Field(alias="authOpenIDLogoutURL")
    client_id: str = Field(alias="authOpenIDClientID")
    client_secret: str | None = Field(alias="authOpenIDClientSecret")
    token_signing_algorithm: str = Field(alias="authOpenIDTokenSigningAlgorithm")
    button_text: str = Field(alias="authOpenIDButtonText")
    auto_launch: StrictBool = Field(alias="authOpenIDAutoLaunch")
    auto_register: StrictBool = Field(alias="authOpenIDAutoRegister")
    match_existing_by: str = Field(alias="authOpenIDMatchExistingBy")
    mobile_redirect_uris: tuple[str, ...] = Field(alias="authOpenIDMobileRedirectURIs")
    group_claim: str = Field(alias="authOpenIDGroupClaim")
    advanced_permissions_claim: str = Field(alias="authOpenIDAdvancedPermsClaim")
    redirect_subfolder: str = Field(alias="authOpenIDSubfolderForRedirectURLs")

    def with_client_secret(self, secret: str) -> OidcSettings:
        return self.model_copy(update={"client_secret": secret})


class BackupSettings(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schedule: str = Field(alias="backupSchedule", min_length=1)
    backups_to_keep: NonNegativeInt = Field(alias="backupsToKeep")
    max_backup_size: NonNegativeInt = Field(alias="maxBackupSize")


class CurrentSettings(RootModel[dict[str, JsonValue]]):
    pass
