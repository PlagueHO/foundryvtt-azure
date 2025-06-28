---
mode: 'ask'
---
Review the C#/.NET code in ${selection} for design pattern implementation and suggest improvements for the GenAI Database Explorer project (.NET 8, C# 12+).

## Required Design Patterns

- **Command Pattern**: Generic base classes (`CommandHandler<TOptions>`), `ICommandHandler<TOptions>` interface, `CommandHandlerOptions` inheritance, static `SetupCommand(IHost host)` methods
- **Factory Pattern**: Complex object creation (`SemanticKernelFactory`, `KernelMemoryFactory`), service provider integration
- **Dependency Injection**: Primary constructor syntax, `ArgumentNullException` null checks, interface abstractions, proper service lifetimes
- **Repository Pattern**: Async data access interfaces (`ISchemaRepository`), provider abstractions for connections
- **Provider Pattern**: External service abstractions (database, AI), clear contracts, configuration handling
- **Resource Pattern**: ResourceManager for localized messages, separate .resx files (LogMessages, ErrorMessages)

## Review Checklist

- **Design Patterns**: Identify patterns used. Are Command Handler, Factory, Provider, and Repository patterns correctly implemented? Missing beneficial patterns?
- **Architecture**: Follow namespace conventions (`GenAIDBExplorer.{Core|Console}.{Feature}`)? Proper separation between Core/Console projects? Modular and readable?
- **.NET Best Practices**: Primary constructors, async/await with Task returns, ResourceManager usage, structured logging, strongly-typed configuration?
- **GoF Patterns**: Command, Factory, Template Method, Strategy patterns correctly implemented?
- **SOLID Principles**: Single Responsibility, Open/Closed, Liskov Substitution, Interface Segregation, Dependency Inversion violations?
- **Performance**: Proper async/await, resource disposal, ConfigureAwait(false), parallel processing opportunities?
- **Maintainability**: Clear separation of concerns, consistent error handling, proper configuration usage?
- **Testability**: Dependencies abstracted via interfaces, mockable components, async testability, AAA pattern compatibility?
- **Security**: Input validation, secure credential handling, parameterized queries, safe exception handling?
- **Documentation**: XML docs for public APIs, parameter/return descriptions, resource file organization?
- **Code Clarity**: Meaningful names reflecting domain concepts, clear intent through patterns, self-explanatory structure?
- **Clean Code**: Consistent style, appropriate method/class size, minimal complexity, eliminated duplication?

## Improvement Focus Areas

- **Command Handlers**: Validation in base class, consistent error handling, proper resource management
- **Factories**: Dependency configuration, service provider integration, disposal patterns  
- **Providers**: Connection management, async patterns, exception handling and logging
- **Configuration**: Data annotations, validation attributes, secure sensitive value handling
- **AI/ML Integration**: Semantic Kernel patterns, structured output handling, model configuration

Provide specific, actionable recommendations for improvements aligned with the GenAI Database Explorer project's architecture and .NET 8 best practices.
