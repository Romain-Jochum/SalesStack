# Task 01: Project Scaffolding

**Depends on:** 00
**Parallel with:** none
**Blocks:** 02
**Outputs:** `backend/package.json`, `backend/tsconfig.json`, `backend/jest.config.ts`, `backend/.eslintrc.json`, `backend/.prettierrc`, `backend/.husky/pre-commit`, `tests/unit/setup.ts`
**Verifies:** Dependencies installed, linting works, TypeScript configured, pre-commit hooks active
**Estimated context:** ~150 lines

## Intent

Bootstrap the backend project with all tooling configured: Node 24, TypeScript, ESLint (strict), Prettier, Jest, and husky pre-commit hooks with lint-staged. Every dependency is pinned to an exact version (no `^` or `~`). This task produces the foundation that all subsequent tasks build on.

## Prerequisites check

- Task 00 (directory structure) is committed and pushed.
- Node.js 24+ and npm 10+ are available locally.
- The `backend/` directory exists but contains no `package.json` yet.

## Steps

### Step 1.1: Create `backend/package.json`

Copy `artifacts/package.json` to `backend/package.json`.

Key properties to verify after copying:
- All dependencies use exact versions (no `^` or `~`)
- `lint-staged` config is present at the top level
- `engines.node` is `>=24.0.0`
- `prepare` script runs `husky install`

### Step 1.2: Create `backend/tsconfig.json`

Copy `artifacts/tsconfig.json` to `backend/tsconfig.json`.

Key properties to verify after copying:
- `target` is `ES2022`, `module` is `CommonJS`
- `strict: true` is enabled
- `outDir` is `./dist`, `rootDir` is `./src`
- `include` covers `src/**/*`, `exclude` covers `node_modules`, `dist`, `tests`

### Step 1.3: Create `backend/jest.config.ts`

Copy `artifacts/jest.config.ts` to `backend/jest.config.ts`.

Key properties to verify after copying:
- `preset` is `ts-jest`, `testEnvironment` is `node`
- `moduleNameMapper` maps `@/` to `<rootDir>/src/`
- `setupFilesAfterEnv` points to `tests/unit/setup.ts`
- `testTimeout` is `30000`

### Step 1.4: Create `backend/.eslintrc.json`

Copy `artifacts/eslintrc.json` to `backend/.eslintrc.json`.

Key properties to verify after copying:
- `@typescript-eslint/no-explicit-any` is `error`
- `no-console` is `warn` (allowing `warn` and `error`)
- `explicit-function-return-type` is `error` with expression allowances
- Test file overrides relax `explicit-function-return-type` and `no-unused-vars`

### Step 1.5: Create `backend/.prettierrc`

```json
{
  "semi": false,
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 100,
  "tabWidth": 2,
  "arrowParens": "always"
}
```

### Step 1.6: Create `tests/unit/setup.ts`

```typescript
// Global test setup — add jest.setTimeout overrides or global mocks here as needed

// Example: increase timeout for slower tests
jest.setTimeout(30000)
```

### Step 1.7: Install dependencies

```bash
cd backend && npm install
```

Expected: `node_modules/` populated, `package-lock.json` created, no errors.

### Step 1.8: Install and configure husky

```bash
cd backend && npx husky install && npx husky add .husky/pre-commit "npx lint-staged"
```

Expected: `.husky/` directory created with `pre-commit` hook.

### Step 1.9: Verify TypeScript compiles

```bash
cd backend && mkdir -p src && echo "export {}" > src/index.ts && npm run typecheck
```

Expected: No errors. Delete `src/index.ts` afterward:

```bash
rm backend/src/index.ts
```

### Step 1.10: Test pre-commit hook

```bash
cd backend && echo "console.log('test')" > test-console.ts && npx lint-staged --diff HEAD
```

Expected: ESLint warns about `no-console`. Clean up:

```bash
rm backend/test-console.ts
```

### Step 1.11: Commit

See commit message below.

## Phase C verification

See `shared/phase-c-template.md` for the general pattern.

This task has no HTTP endpoints or database operations, so Phase C is limited to tooling verification:

- [ ] `npm run typecheck` exits with code 0 (after creating a minimal `src/index.ts`)
- [ ] `npm run lint` exits with code 0 on valid TypeScript
- [ ] `npm run lint` reports errors on code containing `any` type
- [ ] `npm run format` runs without errors
- [ ] `npx lint-staged` triggers ESLint and Prettier on staged `.ts` files
- [ ] `.husky/pre-commit` file exists and contains `npx lint-staged`
- [ ] `npm run test:unit` exits cleanly (no tests yet, but no config errors)
- [ ] All dependencies in `package.json` use exact versions (no `^` or `~`)

## Commit

```
chore: scaffold backend with Node 24, pinned versions, husky pre-commit hooks
```

Files to stage:
```bash
git add backend/package.json backend/package-lock.json backend/tsconfig.json backend/jest.config.ts backend/.eslintrc.json backend/.prettierrc backend/.husky tests/unit/setup.ts
```
