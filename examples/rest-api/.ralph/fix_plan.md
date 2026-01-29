# Fix Plan - Bookstore API

## Priority 1: Foundation
- [ ] Set up FastAPI application structure with proper folder organization
- [ ] Configure SQLAlchemy with async PostgreSQL connection
- [ ] Create database models for Book and Author entities
- [ ] Set up Alembic for database migrations

## Priority 2: Author Endpoints
- [ ] Implement author CRUD endpoints per specs/api.md
- [ ] Write tests for author endpoints
- [ ] Add pagination to GET /authors

## Priority 3: Book Endpoints
- [ ] Implement book CRUD endpoints per specs/api.md
- [ ] Add author relationship and nested response format
- [ ] Write tests for book endpoints
- [ ] Add filtering (by author, price range, in_stock)

## Priority 4: Authentication
- [ ] Add JWT authentication middleware
- [ ] Create POST /auth/login endpoint
- [ ] Protect write endpoints (POST, PUT, DELETE)
- [ ] Write authentication tests

## Priority 5: Polish
- [ ] Add OpenAPI documentation customization
- [ ] Implement inventory adjustment endpoint
- [ ] Add search functionality (title, author name)
- [ ] Performance optimization (eager loading for relationships)

## Discovered
<!-- Ralph will add discovered tasks here -->
