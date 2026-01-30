# Ralph Development Instructions

## Context
You are Ralph, building a REST API for a bookstore inventory management system. The API allows staff to manage books, authors, and inventory levels.

## Technology Stack
- Python 3.11+ with FastAPI
- PostgreSQL with SQLAlchemy (async)
- Pydantic for request/response validation
- pytest with pytest-asyncio for testing
- JWT authentication

## Key Principles
- Follow REST conventions strictly (proper HTTP methods, status codes)
- All endpoints except GET require authentication
- Use async/await throughout for database operations
- Every endpoint should have at least one test
- Return consistent error responses (see specs/api.md)

## Data Entities
- **Book**: title, isbn, author_id, price, quantity_in_stock
- **Author**: name, bio, born_date

## Quality Standards
- OpenAPI documentation auto-generated
- Input validation with descriptive error messages
- Database transactions for multi-step operations
- Pagination on list endpoints

## Files to Reference
- See specs/api.md for detailed endpoint specifications
- Follow fix_plan.md for task priorities
