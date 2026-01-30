# API Specification

## Base URL
All endpoints are prefixed with `/api/v1`

## Authentication
- POST, PUT, DELETE endpoints require JWT in Authorization header
- Format: `Authorization: Bearer <token>`
- GET endpoints are public

## Standard Response Format

### Success (single item)
```json
{
  "data": { ... },
  "meta": {
    "timestamp": "2024-01-15T10:30:00Z"
  }
}
```

### Success (list)
```json
{
  "data": [ ... ],
  "meta": {
    "total": 100,
    "page": 1,
    "per_page": 20,
    "total_pages": 5
  }
}
```

### Error
```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid input",
    "details": {
      "field": "isbn",
      "issue": "ISBN must be 13 characters"
    }
  }
}
```

## Error Codes
| Code | HTTP Status | Description |
|------|-------------|-------------|
| VALIDATION_ERROR | 400 | Invalid input data |
| UNAUTHORIZED | 401 | Missing or invalid token |
| NOT_FOUND | 404 | Resource doesn't exist |
| CONFLICT | 409 | Duplicate ISBN or constraint violation |
| INTERNAL_ERROR | 500 | Unexpected server error |

---

## Author Endpoints

### GET /authors
List all authors with pagination.

**Query Parameters:**
- `page` (int, default: 1)
- `per_page` (int, default: 20, max: 100)

**Response:** 200 OK
```json
{
  "data": [
    {
      "id": 1,
      "name": "Jane Austen",
      "bio": "English novelist...",
      "born_date": "1775-12-16",
      "book_count": 6
    }
  ],
  "meta": { "total": 50, "page": 1, "per_page": 20, "total_pages": 3 }
}
```

### GET /authors/{id}
Get single author with their books.

**Response:** 200 OK
```json
{
  "data": {
    "id": 1,
    "name": "Jane Austen",
    "bio": "English novelist...",
    "born_date": "1775-12-16",
    "books": [
      { "id": 1, "title": "Pride and Prejudice", "isbn": "9780141439518" }
    ]
  }
}
```

### POST /authors
Create new author. Requires authentication.

**Request Body:**
```json
{
  "name": "Jane Austen",
  "bio": "English novelist known for...",
  "born_date": "1775-12-16"
}
```

**Validation:**
- `name`: required, 1-200 characters
- `bio`: optional, max 2000 characters
- `born_date`: optional, ISO date format

**Response:** 201 Created

### PUT /authors/{id}
Update author. Requires authentication.

**Response:** 200 OK

### DELETE /authors/{id}
Delete author. Requires authentication.
Fails if author has books (CONFLICT error).

**Response:** 204 No Content

---

## Book Endpoints

### GET /books
List all books with pagination and filtering.

**Query Parameters:**
- `page`, `per_page` - pagination
- `author_id` (int) - filter by author
- `min_price`, `max_price` (decimal) - price range
- `in_stock` (bool) - only books with quantity > 0

**Response:** 200 OK
```json
{
  "data": [
    {
      "id": 1,
      "title": "Pride and Prejudice",
      "isbn": "9780141439518",
      "price": 12.99,
      "quantity_in_stock": 25,
      "author": {
        "id": 1,
        "name": "Jane Austen"
      }
    }
  ],
  "meta": { ... }
}
```

### GET /books/{id}
Get single book with full author details.

### POST /books
Create new book. Requires authentication.

**Request Body:**
```json
{
  "title": "Pride and Prejudice",
  "isbn": "9780141439518",
  "author_id": 1,
  "price": 12.99,
  "quantity_in_stock": 25
}
```

**Validation:**
- `title`: required, 1-500 characters
- `isbn`: required, exactly 13 characters, unique
- `author_id`: required, must exist
- `price`: required, positive decimal, max 2 decimal places
- `quantity_in_stock`: required, non-negative integer

**Response:** 201 Created

### PUT /books/{id}
Update book. Requires authentication.

### DELETE /books/{id}
Delete book. Requires authentication.

**Response:** 204 No Content

### PATCH /books/{id}/inventory
Adjust inventory level. Requires authentication.

**Request Body:**
```json
{
  "adjustment": -5,
  "reason": "Sold at event"
}
```

**Validation:**
- `adjustment`: required, integer (positive or negative)
- `reason`: required, 1-200 characters
- Final quantity cannot be negative (400 error)

**Response:** 200 OK with updated book

---

## Authentication Endpoints

### POST /auth/login
Authenticate and receive JWT.

**Request Body:**
```json
{
  "username": "admin",
  "password": "secret"
}
```

**Response:** 200 OK
```json
{
  "data": {
    "access_token": "eyJ...",
    "token_type": "bearer",
    "expires_in": 3600
  }
}
```

**Errors:**
- 401 UNAUTHORIZED: Invalid credentials
