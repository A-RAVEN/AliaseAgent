## ADDED Requirements

### Requirement: Attachments column and v6 to v7 migration

The `messages` table SHALL gain a nullable `attachments TEXT` column holding a JSON array of attachment records. Each record SHALL contain only `path` (an absolute file path); image bytes, base64 data, dimensions, and media types MUST NOT be stored in the database.

The schema version SHALL move from 6 to 7. Upgrading an existing database SHALL execute `ALTER TABLE messages ADD COLUMN attachments TEXT` and SHALL preserve every existing row (old rows keep `NULL`, which means "no attachments"). Creating a database from scratch at version 7 SHALL include the column in the `CREATE TABLE messages` statement.

Deserialization SHALL treat `NULL`, malformed JSON, or a non-array value as an empty attachment list, print one log line for the malformed cases, and MUST NOT throw.

#### Scenario: Existing database upgrades
- **WHEN** a version-6 database is opened by code expecting version 7
- **THEN** `ALTER TABLE messages ADD COLUMN attachments TEXT` is executed; every pre-existing message still loads, with an empty attachment list

#### Scenario: Fresh database at version 7
- **WHEN** the database is created from scratch
- **THEN** `CREATE TABLE messages` includes the `attachments` column and the version is 7

#### Scenario: A persisted message round-trips its paths
- **WHEN** a user message with one attached image path is persisted and then reloaded
- **THEN** the reloaded `Message.attachments` equals `[<that path>]` and the row's `attachments` column contains a JSON array whose only element keys come from the set `{path}`

#### Scenario: Malformed column does not crash
- **WHEN** a row's `attachments` column contains `"{not json"`
- **THEN** the message loads with an empty attachment list and one log line is printed
