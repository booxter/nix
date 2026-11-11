INSERT INTO "APIKeys" (userid, apikey)
SELECT userid, 'subscription-test-key' FROM "Users" WHERE username = 'owner';

INSERT INTO "Podcasts" (podcastid, podcastname, feedurl, userid, adskipautoactivate)
SELECT 101, 'Policy test', 'https://example.invalid/first.xml', userid, true
FROM "Users" WHERE username = 'owner';

INSERT INTO "Podcasts" (podcastid, podcastname, feedurl, userid, adskipautoactivate)
VALUES (102, 'Other account', 'https://example.invalid/other.xml', 1, false);

UPDATE "AppSettings" SET downloadenabled = true;
