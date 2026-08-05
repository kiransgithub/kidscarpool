# KCP Pilot v8 Validation

Validation completed in the build environment:

- Every Swift source and test file passed `swiftc -frontend -parse`.
- `Models.swift` passed Swift type checking.
- FastAPI and the workflow smoke-test files passed Python bytecode compilation.
- Backend shell scripts passed `bash -n` syntax validation.
- `SchoolCarpool.xcodeproj/project.pbxproj` passed property-list validation where supported.
- App and backend calendar PDFs have matching SHA-256 fingerprints.
- Backend version and health response are set to `0.8.0`.
- The additive schema includes `ALTER TABLE memberships ALTER COLUMN joined_at DROP NOT NULL`.
- Static inspection confirms `GET /v1/groups`, group-specific snapshot GET/PUT, invitation phone-conflict validation, Groups tab, active-group context and group switching are present.
- The smoke test covers two-group discovery, clean 409 diagnostics for owner-phone reuse, valid invitation creation/acceptance, invited-parent group discovery, constraints, multi-admin roles, calendar analytics, duplicate-calendar prevention and audit persistence.

The Docker/PostgreSQL smoke test and signed physical-iPhone build cannot run in this Linux build environment. Run the included smoke test against the upgraded Mac backend and complete the final build/device test in Xcode.
