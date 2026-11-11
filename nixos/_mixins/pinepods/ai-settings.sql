-- PinePods 0.9.2 resolves each AI request from this singleton, not AI_LLM_*
-- environment variables. Reconcile only the settings owned by this module.
UPDATE "AISettings"
SET LlmBackend = 'remote',
    LlmModel = :'model',
    LlmUrl = :'url',
    LlmApiKey = NULL,
    UpdatedAt = CURRENT_TIMESTAMP
WHERE AISettingsID = 1;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "AISettings" WHERE AISettingsID = 1) THEN
        RAISE EXCEPTION 'PinePods AI settings have not been initialized';
    END IF;
END
$$;
