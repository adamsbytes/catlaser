import eslint from '@eslint/js';
import { defineConfig } from 'eslint/config';
import tseslint from 'typescript-eslint';
import drizzle from 'eslint-plugin-drizzle';
import importX from 'eslint-plugin-import-x';
import unicorn from 'eslint-plugin-unicorn';
import promise from 'eslint-plugin-promise';
import regexp from 'eslint-plugin-regexp';
import security from 'eslint-plugin-security';
import sonarjs from 'eslint-plugin-sonarjs';

const bannedSyntax = [
  {
    selector: 'ForInStatement',
    message: 'Use for...of or Object.entries() instead of for...in.',
  },
  {
    selector: 'TSEnumDeclaration',
    message: 'Use a const object with `as const` or a union type instead of enum.',
  },
  {
    selector: "Identifier[name='eval']",
    message: 'Never use eval().',
  },
  {
    selector: 'LabeledStatement',
    message: 'Labels are almost always wrong. Use a function or restructure the loop.',
  },
  {
    selector: "Identifier[name='arguments']",
    message: 'Use rest parameters instead of arguments.',
  },
  {
    selector: 'UnaryExpression[operator="delete"]',
    message: 'Use destructuring with rest or omit helpers instead of delete.',
  },
  {
    selector: 'WithStatement',
    message: 'with is banned in strict mode and obscures scope.',
  },
  {
    selector: 'SequenceExpression',
    message: 'The comma operator is almost always a bug. Use separate statements.',
  },
  {
    selector: 'TSAsExpression > TSTypeReference > Identifier[name="any"]',
    message: 'Never use `as any`. Fix the types or use `as unknown` with a type guard.',
  },
];

export default defineConfig(
  {
    ignores: ['node_modules/**', 'dist/**', 'coverage/**', '.eslintcache'],
  },

  eslint.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  regexp.configs['flat/all'],

  {
    files: ['**/*.ts'],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },

  {
    files: ['**/*.ts'],
    ...unicorn.configs.recommended,
    rules: {
      ...unicorn.configs.recommended.rules,

      'unicorn/better-regex': 'error',
      'unicorn/consistent-destructuring': 'error',

      'unicorn/catch-error-name': ['error', { name: 'error' }],
      'unicorn/prefer-export-from': ['error', { ignoreUsedVariables: true }],
      'unicorn/prefer-switch': ['error', { minimumCases: 3 }],
      'unicorn/prefer-ternary': ['error', 'only-single-line'],
      'unicorn/switch-case-braces': ['error', 'avoid'],
      'unicorn/filename-case': ['error', { case: 'kebabCase' }],

      'unicorn/no-null': 'off',
      'unicorn/no-array-reduce': 'off',
      'unicorn/prevent-abbreviations': 'off',
      'unicorn/import-style': 'off',
      'unicorn/no-keyword-prefix': 'off',
      'unicorn/string-content': 'off',
    },
  },

  {
    files: ['**/*.ts'],
    plugins: {
      drizzle,
      'import-x': importX,
      promise,
      security,
      sonarjs,
    },
    rules: {
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unnecessary-condition': 'error',

      '@typescript-eslint/no-restricted-types': [
        'error',
        {
          types: {
            Function: { message: 'Use a specific function type like `() => void`.' },
            Object: { message: 'Use `object` or a specific shape.' },
            String: { message: 'Use `string` instead.' },
            Number: { message: 'Use `number` instead.' },
            Boolean: { message: 'Use `boolean` instead.' },
            Symbol: { message: 'Use `symbol` instead.' },
            BigInt: { message: 'Use `bigint` instead.' },
          },
        },
      ],

      '@typescript-eslint/ban-ts-comment': [
        'error',
        {
          'ts-expect-error': 'allow-with-description',
          'ts-ignore': true,
          'ts-nocheck': true,
          minimumDescriptionLength: 10,
        },
      ],

      '@typescript-eslint/consistent-type-imports': [
        'error',
        { prefer: 'type-imports', fixStyle: 'separate-type-imports' },
      ],
      '@typescript-eslint/no-import-type-side-effects': 'error',
      '@typescript-eslint/consistent-type-definitions': ['error', 'interface'],
      '@typescript-eslint/consistent-type-exports': [
        'error',
        { fixMixedExportsWithInlineTypeSpecifier: false },
      ],

      '@typescript-eslint/consistent-type-assertions': [
        'error',
        { assertionStyle: 'as', objectLiteralTypeAssertions: 'never' },
      ],

      '@typescript-eslint/no-confusing-void-expression': [
        'error',
        { ignoreArrowShorthand: true, ignoreVoidOperator: true },
      ],

      '@typescript-eslint/no-floating-promises': ['error', { ignoreVoid: true }],
      '@typescript-eslint/no-misused-promises': 'error',
      '@typescript-eslint/return-await': ['error', 'always'],

      '@typescript-eslint/prefer-nullish-coalescing': 'error',
      '@typescript-eslint/no-non-null-assertion': 'error',
      '@typescript-eslint/prefer-optional-chain': 'error',

      '@typescript-eslint/strict-boolean-expressions': [
        'error',
        {
          allowString: false,
          allowNumber: false,
          allowNullableObject: false,
          allowNullableBoolean: false,
          allowNullableString: false,
          allowNullableNumber: false,
          allowAny: false,
        },
      ],

      'no-shadow': 'off',
      '@typescript-eslint/no-shadow': 'error',

      '@typescript-eslint/related-getter-setter-pairs': 'error',
      'accessor-pairs': 'error',

      '@typescript-eslint/class-methods-use-this': 'error',
      '@typescript-eslint/prefer-reduce-type-parameter': 'error',
      '@typescript-eslint/require-array-sort-compare': ['error', { ignoreStringArrays: true }],
      '@typescript-eslint/promise-function-async': 'error',
      '@typescript-eslint/no-deprecated': 'error',

      'no-useless-constructor': 'off',
      '@typescript-eslint/no-useless-constructor': 'error',

      '@typescript-eslint/prefer-destructuring': [
        'error',
        {
          VariableDeclarator: { array: false, object: true },
          AssignmentExpression: { array: false, object: false },
        },
      ],

      '@typescript-eslint/no-unnecessary-parameter-property-assignment': 'error',
      '@typescript-eslint/prefer-readonly': 'error',
      '@typescript-eslint/prefer-return-this-type': 'error',
      '@typescript-eslint/max-params': ['error', { max: 4 }],
      '@typescript-eslint/no-unsafe-type-assertion': 'error',
      '@typescript-eslint/no-misused-spread': 'error',

      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
          destructuredArrayIgnorePattern: '^_',
        },
      ],

      '@typescript-eslint/no-unused-expressions': 'error',
      '@typescript-eslint/no-unnecessary-type-parameters': 'error',
      '@typescript-eslint/no-unnecessary-qualifier': 'error',

      '@typescript-eslint/restrict-template-expressions': ['error', { allowNumber: true }],
      '@typescript-eslint/no-unnecessary-template-expression': 'error',

      '@typescript-eslint/switch-exhaustiveness-check': [
        'error',
        { requireDefaultForNonUnion: true },
      ],

      '@typescript-eslint/method-signature-style': ['error', 'property'],
      '@typescript-eslint/explicit-module-boundary-types': 'error',

      '@typescript-eslint/naming-convention': [
        'error',
        { selector: 'typeLike', format: ['PascalCase'] },
        { selector: 'enumMember', format: ['UPPER_CASE', 'PascalCase'] },
        {
          selector: 'variable',
          modifiers: ['const', 'exported'],
          format: ['camelCase', 'PascalCase', 'UPPER_CASE'],
        },
        {
          selector: 'variable',
          types: ['boolean'],
          format: ['camelCase', 'PascalCase'],
          prefix: ['is', 'has', 'should', 'can', 'did', 'will', 'was', 'does', 'need'],
          filter: { regex: '^_', match: false },
        },
        { selector: 'function', format: ['camelCase', 'PascalCase'] },
        { selector: 'parameter', format: ['camelCase'], leadingUnderscore: 'allow' },
      ],

      'no-void': ['error', { allowAsStatement: true }],
      eqeqeq: ['error', 'always'],

      '@typescript-eslint/default-param-last': 'error',

      'no-caller': 'error',
      'no-bitwise': 'error',
      'no-lone-blocks': 'error',
      'no-await-in-loop': 'error',
      'require-atomic-updates': 'error',

      'no-var': 'error',
      'no-new-wrappers': 'error',
      'no-multi-assign': 'error',
      'no-alert': 'error',
      'prefer-spread': 'error',
      'prefer-rest-params': 'error',
      'no-constant-binary-expression': 'error',
      'prefer-const': 'error',
      'no-console': 'error',
      curly: ['error', 'all'],
      'no-else-return': ['error', { allowElseIf: false }],

      'no-unneeded-ternary': ['error', { defaultAssignment: false }],
      'prefer-template': 'error',
      'object-shorthand': 'error',
      'no-useless-rename': 'error',
      'no-useless-computed-key': 'error',
      'no-param-reassign': 'error',

      'no-self-compare': 'error',
      'no-template-curly-in-string': 'error',
      'no-constructor-return': 'error',
      'no-promise-executor-return': 'error',
      'no-return-assign': ['error', 'always'],
      'no-sequences': 'error',
      'no-implicit-coercion': 'error',
      'array-callback-return': ['error', { allowImplicit: false }],
      'prefer-object-spread': 'error',
      'prefer-object-has-own': 'error',
      'no-script-url': 'error',
      'no-proto': 'error',

      'no-loop-func': 'off',
      '@typescript-eslint/no-loop-func': 'error',
      'no-new-func': 'error',
      'no-extend-native': 'error',
      'default-case-last': 'error',
      'no-object-constructor': 'error',
      'no-unused-private-class-members': 'error',

      'no-useless-catch': 'error',
      'no-unreachable-loop': 'error',
      'no-useless-assignment': 'error',
      'no-restricted-globals': [
        'error',
        { name: 'event', message: 'Use local parameter instead.' },
        { name: 'isNaN', message: 'Use Number.isNaN() instead.' },
        { name: 'isFinite', message: 'Use Number.isFinite() instead.' },
        { name: 'parseInt', message: 'Use Number.parseInt() instead.' },
        { name: 'parseFloat', message: 'Use Number.parseFloat() instead.' },
      ],

      '@typescript-eslint/no-use-before-define': [
        'error',
        { functions: false, classes: true, variables: true },
      ],

      '@typescript-eslint/dot-notation': ['error', { allowIndexSignaturePropertyAccess: true }],
      '@typescript-eslint/prefer-includes': 'error',
      '@typescript-eslint/prefer-string-starts-ends-with': 'error',
      '@typescript-eslint/prefer-regexp-exec': 'error',
      '@typescript-eslint/prefer-find': 'error',
      '@typescript-eslint/no-unnecessary-type-arguments': 'error',

      'consistent-return': 'off',
      '@typescript-eslint/consistent-return': 'error',

      '@typescript-eslint/no-useless-empty-export': 'error',
      '@typescript-eslint/no-require-imports': 'error',

      'no-restricted-imports': [
        'error',
        {
          paths: [{ name: 'zod/v4', message: 'Import from "zod" instead of "zod/v4".' }],
        },
      ],

      'no-restricted-syntax': ['error', ...bannedSyntax],

      'import-x/first': 'error',
      'import-x/no-cycle': 'error',
      'import-x/no-duplicates': 'error',
      'import-x/no-self-import': 'error',
      'import-x/no-extraneous-dependencies': 'error',
      'import-x/no-mutable-exports': 'error',
      'import-x/no-useless-path-segments': 'error',
      'import-x/no-named-as-default': 'error',
      'import-x/no-named-as-default-member': 'error',
      'import-x/no-default-export': 'error',
      'import-x/no-namespace': 'error',
      'import-x/no-absolute-path': 'error',
      'import-x/no-empty-named-blocks': 'error',
      'import-x/no-commonjs': 'error',
      'import-x/no-amd': 'error',

      'drizzle/enforce-delete-with-where': ['error', { drizzleObjectName: ['db', 'tx'] }],
      'drizzle/enforce-update-with-where': ['error', { drizzleObjectName: ['db', 'tx'] }],

      'promise/no-return-wrap': 'error',
      'promise/param-names': 'error',
      'promise/catch-or-return': 'error',
      'promise/no-new-statics': 'error',
      'promise/no-return-in-finally': 'error',
      'promise/valid-params': 'error',
      'promise/no-multiple-resolved': 'error',
      'promise/no-nesting': 'error',
      'promise/no-promise-in-callback': 'error',
      'promise/no-callback-in-promise': 'error',
      'promise/prefer-await-to-then': 'error',
      'promise/prefer-await-to-callbacks': 'error',

      'no-restricted-properties': [
        'error',
        {
          object: 'Math',
          property: 'random',
          message: 'Use crypto.getRandomValues() or crypto.randomUUID() instead.',
        },
      ],

      'security/detect-buffer-noassert': 'error',
      'security/detect-child-process': 'error',
      'security/detect-disable-mustache-escape': 'error',
      'security/detect-eval-with-expression': 'error',
      'security/detect-new-buffer': 'error',
      'security/detect-no-csrf-before-method-override': 'error',
      'security/detect-non-literal-fs-filename': 'error',
      'security/detect-non-literal-regexp': 'error',
      'security/detect-non-literal-require': 'error',
      'security/detect-possible-timing-attacks': 'error',
      'security/detect-pseudoRandomBytes': 'error',
      'security/detect-unsafe-regex': 'error',
      'security/detect-bidi-characters': 'error',

      ...sonarjs.configs.recommended.rules,

      'sonarjs/cognitive-complexity': ['error', 10],

      'sonarjs/no-collapsible-if': 'error',
      'sonarjs/no-nested-switch': 'error',
      'sonarjs/no-incorrect-string-concat': 'error',
      'sonarjs/values-not-convertible-to-numbers': 'error',
      'sonarjs/operation-returning-nan': 'error',
      'sonarjs/useless-string-operation': 'error',
      'sonarjs/prefer-immediate-return': 'error',
      'sonarjs/prefer-object-literal': 'error',
      'sonarjs/non-number-in-arithmetic-expression': 'error',
      'sonarjs/no-built-in-override': 'error',

      'sonarjs/no-unused-vars': 'off',
      'sonarjs/unused-import': 'off',
      'sonarjs/deprecation': 'off',
      'sonarjs/no-parameter-reassignment': 'off',
      'sonarjs/no-useless-catch': 'off',
      'sonarjs/no-fallthrough': 'off',
      'sonarjs/no-delete-var': 'off',
      'sonarjs/updated-const-var': 'off',
      'sonarjs/block-scoped-var': 'off',
      'sonarjs/bitwise-operators': 'off',
      'sonarjs/no-primitive-wrappers': 'off',
      'sonarjs/class-name': 'off',
      'sonarjs/no-extra-arguments': 'off',
      'sonarjs/array-callback-without-return': 'off',
      'sonarjs/prefer-regexp-exec': 'off',
      'sonarjs/no-alphabetical-sort': 'off',
      'sonarjs/pseudo-random': 'off',
      'sonarjs/code-eval': 'off',
      'sonarjs/no-labels': 'off',
      'sonarjs/label-position': 'off',
      'sonarjs/no-regex-spaces': 'off',
      'sonarjs/no-control-regex': 'off',
      'sonarjs/no-invalid-regexp': 'off',
      'sonarjs/no-unenclosed-multiline-block': 'off',
      'sonarjs/for-loop-increment-sign': 'off',
      'sonarjs/no-globals-shadowing': 'off',
      'sonarjs/function-return-type': 'off',
      'sonarjs/cyclomatic-complexity': 'off',
      'sonarjs/no-global-this': 'off',
      'sonarjs/generator-without-yield': 'off',
      'sonarjs/no-implicit-global': 'off',
      'sonarjs/future-reserved-words': 'off',
      'sonarjs/argument-type': 'off',
      'sonarjs/anchor-precedence': 'off',
      'sonarjs/concise-regex': 'off',
      'sonarjs/duplicates-in-character-class': 'off',
      'sonarjs/empty-string-repetition': 'off',
      'sonarjs/existing-groups': 'off',
      'sonarjs/no-empty-after-reluctant': 'off',
      'sonarjs/no-empty-alternatives': 'off',
      'sonarjs/no-empty-character-class': 'off',
      'sonarjs/no-empty-group': 'off',
      'sonarjs/no-misleading-character-class': 'off',
      'sonarjs/single-char-in-character-classes': 'off',
      'sonarjs/single-character-alternation': 'off',
      'sonarjs/slow-regex': 'off',
      'sonarjs/stateful-regex': 'off',
      'sonarjs/regex-complexity': 'off',
      'sonarjs/unused-named-groups': 'off',
      'sonarjs/no-array-delete': 'off',

      'sonarjs/todo-tag': 'off',
      'sonarjs/fixme-tag': 'off',
      'sonarjs/no-commented-code': 'off',
      'sonarjs/no-nested-functions': 'off',
      'sonarjs/no-same-line-conditional': 'off',
      'sonarjs/call-argument-line': 'off',
      'sonarjs/prefer-while': 'off',
      'sonarjs/no-nested-conditional': 'off',
      'sonarjs/max-switch-cases': 'off',
      'sonarjs/redundant-type-aliases': 'off',
      'sonarjs/use-type-alias': 'off',
      'sonarjs/prefer-type-guard': 'off',
      'sonarjs/no-small-switch': 'off',
      'sonarjs/no-case-label-in-switch': 'off',
      'sonarjs/prefer-read-only-props': 'off',

      'sonarjs/jsx-no-leaked-render': 'off',
      'sonarjs/no-hook-setter-in-body': 'off',
      'sonarjs/no-useless-react-setstate': 'off',
      'sonarjs/no-angular-bypass-sanitization': 'off',
      'sonarjs/no-vue-bypass-sanitization': 'off',
      'sonarjs/no-table-as-layout': 'off',
      'sonarjs/table-header': 'off',
      'sonarjs/table-header-reference': 'off',
      'sonarjs/object-alt-content': 'off',
      'sonarjs/no-uniq-key': 'off',
      'sonarjs/link-with-target-blank': 'off',
      'sonarjs/disabled-auto-escaping': 'off',
      'sonarjs/disabled-resource-integrity': 'off',
      'sonarjs/aws-restricted-ip-admin-access': 'off',

      complexity: ['error', 10],
      'max-depth': ['error', 3],

      'no-new': 'error',
    },
  },

  {
    files: ['src/routes/**/*.ts'],
    rules: {
      'no-restricted-syntax': [
        'error',
        ...bannedSyntax,
        {
          selector: "CallExpression[callee.object.name='Response'][callee.property.name='json']",
          message:
            'Use successResponse()/errorResponse() from ~/lib/http.ts instead of Response.json().',
        },
        {
          selector: "NewExpression[callee.name='Response']",
          message:
            'Use successResponse()/errorResponse() from ~/lib/http.ts instead of new Response().',
        },
        {
          selector: "CallExpression[callee.object.name='db'][callee.property.name='insert']",
          message: 'Route handlers must not call db.insert(). Use a domain function instead.',
        },
        {
          selector: "CallExpression[callee.object.name='db'][callee.property.name='update']",
          message: 'Route handlers must not call db.update(). Use a domain function instead.',
        },
        {
          selector: "CallExpression[callee.object.name='db'][callee.property.name='delete']",
          message: 'Route handlers must not call db.delete(). Use a domain function instead.',
        },
        {
          selector: "CallExpression[callee.object.name='db'][callee.property.name='transaction']",
          message:
            'Route handlers must not call db.transaction(). Transactions belong in the domain layer.',
        },
      ],
    },
  },

  {
    files: ['**/*.{js,mjs,cjs}'],
    ...tseslint.configs.disableTypeChecked,
  },

  {
    files: ['*.config.{js,ts,mjs}', 'eslint.config.js', 'drizzle.config.ts'],
    rules: {
      'no-console': 'off',
      '@typescript-eslint/explicit-module-boundary-types': 'off',
      'import-x/no-default-export': 'off',
      'sonarjs/no-dead-store': 'off',
    },
  },

  {
    files: ['**/*.test.ts', 'test/**/*.ts'],
    rules: {
      'no-console': 'off',
      '@typescript-eslint/explicit-module-boundary-types': 'off',
      'no-param-reassign': 'off',
      'sonarjs/no-parameter-reassignment': 'off',
      'unicorn/consistent-function-scoping': 'off',
      'sonarjs/no-identical-functions': 'off',
      'sonarjs/no-hardcoded-passwords': 'off',
      'sonarjs/no-hardcoded-secrets': 'off',
      'sonarjs/no-hardcoded-ip': 'off',
      'sonarjs/no-clear-text-protocols': 'off',
      'sonarjs/stable-tests': 'off',
      'no-restricted-syntax': [
        'error',
        ...bannedSyntax,
        {
          selector: "CallExpression[callee.object.name='describe'][callee.property.name='only']",
          message: 'Do not commit describe.only -- it skips other tests.',
        },
        {
          selector: "CallExpression[callee.object.name='it'][callee.property.name='only']",
          message: 'Do not commit it.only -- it skips other tests.',
        },
        {
          selector: "CallExpression[callee.object.name='test'][callee.property.name='only']",
          message: 'Do not commit test.only -- it skips other tests.',
        },
      ],
      'sonarjs/assertions-in-tests': 'error',
      'sonarjs/inverted-assertion-arguments': 'error',
      'sonarjs/no-incomplete-assertions': 'error',
      'sonarjs/no-same-argument-assert': 'error',
      'sonarjs/no-skipped-tests': 'error',
      'sonarjs/no-empty-test-file': 'error',
    },
  },
);
