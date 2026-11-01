// The JSON Schema subset gh-touchid declares (`--help --json`): type (a name, or a list with "null"), properties,
// required, additionalProperties false, enum, pattern, minimum, maximum, items, description, writeOnly. `schemaProblems`
// checks a schema uses only that subset, consistently; `valueProblems` checks a value against one, independently of
// gh-touchid's own checks.

export type JsonSchema = Record<string, unknown>;

const keywords: Record<string, true> = {
  type: true,
  properties: true,
  required: true,
  additionalProperties: true,
  enum: true,
  pattern: true,
  minimum: true,
  maximum: true,
  items: true,
  description: true,
  writeOnly: true,
};
const types: Record<string, true> = { object: true, string: true, integer: true, boolean: true, array: true, null: true };

function typesOf(schema: JsonSchema): string[] {
  return Array.isArray(schema.type) ? (schema.type as string[]) : [schema.type as string];
}

/** What is wrong with `schema` as a declaration; empty when nothing is. */
export function schemaProblems(schema: JsonSchema, path = "$"): string[] {
  const problems: string[] = [];
  for (const key of Object.keys(schema)) {
    if (!keywords[key]) {
      problems.push(`${path}: unknown keyword ${key}`);
    }
  }
  const declared = typesOf(schema);
  if (declared.length === 0 || !declared.every((type) => types[type])) {
    problems.push(`${path}: bad type ${JSON.stringify(schema.type)}`);
  }
  if (Array.isArray(schema.type) && !(schema.type.length === 2 && schema.type[1] === "null")) {
    problems.push(`${path}: a type list must be [type, "null"]`);
  }
  if (schema.description !== undefined && typeof schema.description !== "string") {
    problems.push(`${path}: description must be a string`);
  }
  if (declared.includes("object")) {
    const properties = schema.properties as Record<string, JsonSchema> | undefined;
    if (typeof properties !== "object" || properties === null) {
      problems.push(`${path}: an object needs properties`);
    } else {
      for (const [name, property] of Object.entries(properties)) {
        if (!/^[a-z][a-z0-9_]*$/.test(name)) {
          problems.push(`${path}.${name}: field names are snake_case`);
        }
        problems.push(...schemaProblems(property, `${path}.${name}`));
      }
      for (const name of (schema.required as string[] | undefined) ?? []) {
        if (!(name in properties)) {
          problems.push(`${path}: required ${name} is not a property`);
        }
      }
    }
    if (schema.additionalProperties !== false) {
      problems.push(`${path}: objects take no additional properties`);
    }
  }
  if (declared.includes("array")) {
    if (typeof schema.items !== "object") {
      problems.push(`${path}: an array needs items`);
    } else {
      problems.push(...schemaProblems(schema.items as JsonSchema, `${path}[]`));
    }
  }
  if (schema.pattern !== undefined) {
    try {
      new RegExp(schema.pattern as string, "u");
    } catch {
      problems.push(`${path}: pattern does not compile`);
    }
  }
  if (schema.writeOnly !== undefined && !(schema.writeOnly === true && declared.includes("string"))) {
    problems.push(`${path}: writeOnly is for secret strings`);
  }
  return problems;
}

/** What is wrong with `value` under `schema`; empty when it fits. */
export function valueProblems(schema: JsonSchema, value: unknown, path = "$"): string[] {
  const declared = typesOf(schema);
  const actual =
    value === null
      ? "null"
      : Array.isArray(value)
        ? "array"
        : typeof value === "number"
          ? Number.isInteger(value)
            ? "integer"
            : "number"
          : typeof value;
  if (!declared.includes(actual)) {
    return [`${path}: ${actual} is not ${declared.join(" or ")}`];
  }
  if (actual === "null") {
    return [];
  }
  const problems: string[] = [];
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) {
    problems.push(`${path}: not in the enum`);
  }
  if (actual === "string" && typeof schema.pattern === "string" && !new RegExp(schema.pattern, "u").test(value as string)) {
    problems.push(`${path}: does not match ${schema.pattern}`);
  }
  if (actual === "integer") {
    if (typeof schema.minimum === "number" && (value as number) < schema.minimum) {
      problems.push(`${path}: below the minimum`);
    }
    if (typeof schema.maximum === "number" && (value as number) > schema.maximum) {
      problems.push(`${path}: above the maximum`);
    }
  }
  if (actual === "array") {
    (value as unknown[]).forEach((item, index) =>
      problems.push(...valueProblems(schema.items as JsonSchema, item, `${path}[${index}]`)),
    );
  }
  if (actual === "object") {
    const properties = (schema.properties ?? {}) as Record<string, JsonSchema>;
    const object = value as Record<string, unknown>;
    for (const key of Object.keys(object)) {
      if (!(key in properties)) {
        problems.push(`${path}.${key}: not declared`);
      } else {
        problems.push(...valueProblems(properties[key]!, object[key], `${path}.${key}`));
      }
    }
    for (const name of (schema.required as string[] | undefined) ?? []) {
      if (!(name in object)) {
        problems.push(`${path}.${name}: missing`);
      }
    }
  }
  return problems;
}
