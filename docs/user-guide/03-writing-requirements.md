# Writing Effective Requirements

Ralph works best when it understands what you want. This guide shows you how to write clear requirements in PROMPT.md, when to use specs/, and how fix_plan.md evolves during development.

## PROMPT.md: Good vs Bad Examples

### Bad Example

```markdown
# Project

Make a good API for managing stuff. Use best practices.
Should be fast and work well.
```

**Problems**:
- What "stuff"? Too vague.
- What are "best practices"? Claude will guess.
- "Fast" and "work well" aren't measurable.

### Good Example

```markdown
# Ralph Development Instructions

## Context
You are Ralph, building a REST API for a pet adoption shelter.
The API manages animals, adopters, and adoption records.

## Technology Stack
- Python 3.11+ with FastAPI
- PostgreSQL with SQLAlchemy (async)
- pytest for testing
- Pydantic for validation

## Key Principles
- RESTful endpoints following standard conventions
- All endpoints require authentication except GET /animals
- Soft delete for all entities (is_deleted flag, not actual deletion)
- Pagination on all list endpoints (default 20, max 100)

## Data Entities
- Animal: name, species, breed, age, status (available/adopted/pending)
- Adopter: name, email, phone, approved (boolean)
- Adoption: animal_id, adopter_id, date, status

## Quality Standards
- Every endpoint needs at least one happy-path test
- Input validation with clear error messages
- OpenAPI documentation for all endpoints
```

**Why this works**:
- Clear domain (pet adoption shelter)
- Specific technology choices
- Measurable constraints (pagination limits)
- Concrete data model
- Defined quality bar

## fix_plan.md: Task Writing

### The Goldilocks Principle

Tasks should be **not too big, not too small**.

**Too big** (Ralph doesn't know where to start):
```markdown
- [ ] Build the entire authentication system
```

**Too small** (wastes loop iterations):
```markdown
- [ ] Create the auth folder
- [ ] Create the auth/__init__.py file
- [ ] Create the auth/routes.py file
```

**Just right** (one loop of meaningful work):
```markdown
- [ ] Create auth routes with POST /login and POST /logout endpoints
- [ ] Add JWT token generation and validation middleware
- [ ] Create refresh token endpoint POST /auth/refresh
```

### Task Structure Template

```markdown
# Fix Plan - [Project Name]

## Priority 1: [Foundation/Critical Path]
- [ ] [Specific, actionable task]
- [ ] [Another specific task]

## Priority 2: [Core Features]
- [ ] [Feature task]
- [ ] [Feature task]

## Priority 3: [Polish/Nice-to-have]
- [ ] [Enhancement]
- [ ] [Documentation]

## Discovered
<!-- Ralph adds tasks it discovers here -->
```

### How fix_plan.md Evolves

**Initial state** (you write this):
```markdown
## Priority 1: Database
- [ ] Set up database models for Animal, Adopter, Adoption

## Priority 2: API
- [ ] Create CRUD endpoints for animals
```

**After Loop 1** (Ralph updates):
```markdown
## Priority 1: Database
- [x] Set up database models for Animal, Adopter, Adoption

## Priority 2: API
- [ ] Create CRUD endpoints for animals

## Discovered
- [ ] Add database migration with Alembic
- [ ] Create pytest fixtures for test database
```

**After Loop 3**:
```markdown
## Priority 1: Database
- [x] Set up database models for Animal, Adopter, Adoption

## Priority 2: API
- [x] Create CRUD endpoints for animals
- [ ] Create CRUD endpoints for adopters

## Discovered
- [x] Add database migration with Alembic
- [x] Create pytest fixtures for test database
- [ ] Add pagination to GET /animals endpoint
```

Ralph adds tasks it discovers and checks them off as it works. You can:
- Reorder tasks by moving them to different priority sections
- Delete tasks that are no longer relevant
- Add new tasks anytime

## When to Use specs/

### Use specs/ for complex features

**PROMPT.md says**:
```markdown
Add a matching algorithm that suggests animals to adopters.
```

**This is too vague.** Create `.ralph/specs/matching-algorithm.md`:
```markdown
# Animal Matching Algorithm

## Inputs
- Adopter preferences: species, max_age, size_preference
- Available animals list

## Algorithm
1. Filter by species (required match)
2. Score by age preference (0-100 points)
   - Within range: 100 points
   - Within 2 years: 50 points
   - Outside: 0 points
3. Score by size preference (0-50 points)
4. Return top 5 by total score

## Output Format
```json
[
  {"animal_id": 1, "score": 145, "reasons": ["species match", "age within preference"]},
  {"animal_id": 3, "score": 120, "reasons": ["species match"]}
]
```

## Edge Cases
- No matches: return empty array
- Tie scores: sort by animal.created_at (oldest first)
```

**Then in fix_plan.md**:
```markdown
- [ ] Implement matching algorithm per specs/matching-algorithm.md
```

### Use specs/stdlib/ for conventions

When you want consistency across the project, document it:

`.ralph/specs/stdlib/error-responses.md`:
```markdown
# Error Response Standard

All API errors return this structure:

```json
{
  "error": {
    "code": "ANIMAL_NOT_FOUND",
    "message": "No animal with ID 42 exists",
    "field": null,
    "details": {}
  }
}
```

## Error Codes
| Code | HTTP Status | When |
|------|-------------|------|
| VALIDATION_ERROR | 400 | Invalid input |
| NOT_FOUND | 404 | Resource doesn't exist |
| ALREADY_ADOPTED | 409 | Animal not available |
| UNAUTHORIZED | 401 | Missing/invalid token |
```

### Don't use specs/ for everything

**Overkill** - You don't need specs/ for:
```markdown
# User Password Requirements

Passwords must be at least 8 characters.
```

**Just put it in PROMPT.md**:
```markdown
## Authentication
- Passwords: minimum 8 characters, at least one number
- JWT tokens expire after 1 hour
```

## Common Mistakes

### Mistake 1: Assuming Claude knows your preferences

**Bad**:
```markdown
Use standard authentication.
```

**Good**:
```markdown
Use JWT authentication with 1-hour token expiry.
Refresh tokens last 7 days and rotate on use.
```

### Mistake 2: Mixing implementation with requirements

**Bad** (in PROMPT.md):
```markdown
Create a file called auth.py and add these imports:
import jwt
from datetime import datetime
```

**Good** (in PROMPT.md):
```markdown
Use JWT for authentication. Tokens should expire after 1 hour.
```

Let Ralph figure out the implementation details.

### Mistake 3: Over-specifying tests

**Bad**:
```markdown
- [ ] Write test_create_animal_success
- [ ] Write test_create_animal_invalid_species
- [ ] Write test_create_animal_missing_name
- [ ] Write test_create_animal_negative_age
```

**Good**:
```markdown
- [ ] Write tests for animal creation (success and validation errors)
```

Ralph knows how to write tests. Tell it what to test, not how.

### Mistake 4: Forgetting the "why"

**Bad**:
```markdown
Add a 100ms delay to all API responses.
```

**Good**:
```markdown
Add a 100ms delay to all API responses (required for rate limiting compliance with external payment API).
```

When Ralph understands *why*, it makes better decisions.

## Checklist: Before Running Ralph

Before `ralph --monitor`, verify:

- [ ] **PROMPT.md has clear context** - Does Ralph know what it's building?
- [ ] **Technology stack is specified** - Did you pick the frameworks?
- [ ] **Key constraints are documented** - Auth approach? API conventions?
- [ ] **fix_plan.md has specific tasks** - Can Ralph start on task 1 immediately?
- [ ] **Complex features have specs/** - Is anything too vague for PROMPT.md?

If you can answer "yes" to these, Ralph will do good work.

## Quick Reference

| Need to... | Put it in... |
|------------|--------------|
| Set project vision and principles | PROMPT.md |
| Define technology stack | PROMPT.md |
| List specific implementation tasks | fix_plan.md |
| Document complex feature requirements | specs/feature-name.md |
| Establish coding conventions | specs/stdlib/convention-name.md |
| Configure Ralph behavior | .ralphrc |
