# Example: REST API with Specifications

This example shows a medium-complexity Ralph configuration for a bookstore REST API. It demonstrates when and how to use the specs/ directory.

## What This Example Demonstrates

- **Focused PROMPT.md** - High-level goals and principles
- **Detailed specs/api.md** - Endpoint specifications that are too detailed for PROMPT.md
- **Structured fix_plan.md** - Tasks organized by feature area

## Project Structure

```
rest-api/
├── .ralph/
│   ├── PROMPT.md         # Project vision and principles
│   ├── fix_plan.md       # Implementation tasks
│   └── specs/
│       └── api.md        # Detailed API specifications
├── .ralphrc              # Configuration (auto-generated)
└── README.md             # This file
```

## Why This Example Uses specs/

The PROMPT.md keeps things high-level:
- What the API is for (bookstore inventory)
- Technology stack (FastAPI, PostgreSQL)
- Key principles (REST conventions, authentication)

But the API needs detailed specifications that would clutter PROMPT.md:
- Exact request/response formats
- Validation rules
- Error codes
- Pagination behavior

That's what `specs/api.md` is for.

## How to Use This Example

1. Copy this directory to a new location:
   ```bash
   cp -r examples/rest-api ~/my-bookstore-api
   cd ~/my-bookstore-api
   ```

2. Initialize git and Python environment:
   ```bash
   git init
   python -m venv venv
   source venv/bin/activate
   pip install fastapi uvicorn sqlalchemy pytest
   ```

3. Run Ralph:
   ```bash
   ralph --monitor
   ```

## Key Points

### PROMPT.md Sets Direction

PROMPT.md answers "what are we building and how?" without getting into implementation details.

### specs/api.md Provides Details

When you need to specify:
- Exact endpoint paths and methods
- Request/response schemas
- Business rules and constraints
- Error handling behavior

These details help Ralph implement correctly on the first try.

### fix_plan.md References specs/

Notice how tasks reference the specification:
```markdown
- [ ] Implement book endpoints per specs/api.md
```

This tells Ralph where to find the detailed requirements.

## When to Add More Specs

Consider adding additional spec files for:
- **specs/database.md** - Schema details, relationships, indexes
- **specs/auth.md** - Token formats, permission rules, session handling
- **specs/stdlib/errors.md** - Standard error response format
- **specs/stdlib/pagination.md** - Pagination conventions

## Comparison with Simple Example

| Aspect | Simple CLI | REST API |
|--------|-----------|----------|
| Complexity | Low | Medium |
| Uses specs/ | No | Yes |
| PROMPT.md length | ~40 lines | ~30 lines |
| Why | Self-contained | API contracts need detail |
