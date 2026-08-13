const fs = require("node:fs");
const ts = require(process.env.TYPESCRIPT_LIB);

function argument(name) {
  const position = process.argv.indexOf(name);
  if (position === -1 || position + 1 >= process.argv.length) {
    throw new Error(`missing ${name}`);
  }
  return process.argv[position + 1];
}

function goName(value) {
  return value
    .split("_")
    .map((part) => part.charAt(0) + part.slice(1).toLowerCase())
    .join("");
}

function parseEnum(path, expectedName) {
  const source = fs.readFileSync(path, "utf8");
  const sourceFile = ts.createSourceFile(
    path,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  if (sourceFile.parseDiagnostics.length !== 0) {
    throw new Error(`TypeScript parser rejected ${path}`);
  }
  const declarations = sourceFile.statements.filter(
    (statement) =>
      ts.isEnumDeclaration(statement) && statement.name.text === expectedName,
  );
  if (declarations.length !== 1) {
    throw new Error(
      `expected one ${expectedName} enum in ${path}, found ${declarations.length}`,
    );
  }
  return declarations[0].members.map((member) => {
    if (!ts.isIdentifier(member.name)) {
      throw new Error(`${expectedName} contains a non-identifier member`);
    }
    if (member.initializer === undefined || !ts.isNumericLiteral(member.initializer)) {
      throw new Error(
        `${expectedName}.${member.name.text} does not have a numeric literal initializer`,
      );
    }
    return [member.name.text, Number(member.initializer.text)];
  });
}

const enums = [
  ["Permission", parseEnum(argument("--permissions"), "Permission")],
  ["Notification", parseEnum(argument("--notifications"), "Notification")],
];
const output = [
  "// Code generated from Seerr TypeScript enums. DO NOT EDIT.",
  "package seerrapi",
  "",
];
for (const [prefix, values] of enums) {
  output.push("const (");
  for (const [name, value] of values) {
    output.push(`\t${prefix}${goName(name)} = ${value}`);
  }
  output.push(")", "");
}
process.stdout.write(`${output.join("\n")}\n`);
