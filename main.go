package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/valkey-io/valkey-go"
)

type Server struct {
	client    valkey.Client
	router    *http.ServeMux
	authToken string
}

type Config struct {
	Port           string
	ValkeyAddress  string
	ValkeyPassword string
	AuthToken      string
	ReadTimeout    time.Duration
	WriteTimeout   time.Duration
	IdleTimeout    time.Duration
}

type ErrorResponse struct {
	Error string `json:"error"`
}

type SetRequest struct {
	Value      string `json:"value"`
	Expiration int64  `json:"expiration,omitempty"` // Expiration in seconds
}

type GetResponse struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func NewServer(client valkey.Client, authToken string) *Server {
	s := &Server{
		client:    client,
		router:    http.NewServeMux(),
		authToken: authToken,
	}
	s.setupRoutes()
	return s
}

// authMiddleware validates the Authorization token
func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// If no auth token is configured, allow all requests
		if s.authToken == "" {
			next(w, r)
			return
		}

		// Check Authorization header
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(ErrorResponse{Error: "authorization token required"})
			return
		}

		// Support both "Bearer <token>" and direct token
		token := authHeader
		if len(authHeader) > 7 && authHeader[:7] == "Bearer " {
			token = authHeader[7:]
		}

		if token != s.authToken {
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(ErrorResponse{Error: "invalid authorization token"})
			return
		}

		next(w, r)
	}
}

func (s *Server) setupRoutes() {
	// Health check is public (no auth required)
	s.router.HandleFunc("GET /health", s.handleHealth)
	
	// Protected endpoints require authentication
	s.router.HandleFunc("GET /keys/{key}", s.authMiddleware(s.handleGet))
	s.router.HandleFunc("POST /keys/{key}", s.authMiddleware(s.handleSet))
	s.router.HandleFunc("DELETE /keys/{key}", s.authMiddleware(s.handleDelete))
	s.router.HandleFunc("GET /keys", s.authMiddleware(s.handleList))
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	// Test Valkey connection
	_, err := s.client.Do(ctx, s.client.B().Ping().Build()).ToString()
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "Valkey connection failed"})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}

func (s *Server) handleGet(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if key == "" {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "key is required"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	result, err := s.client.Do(ctx, s.client.B().Get().Key(key).Build()).ToString()
	if err != nil {
		if err == valkey.Nil {
			w.WriteHeader(http.StatusNotFound)
			json.NewEncoder(w).Encode(ErrorResponse{Error: "key not found"})
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "internal server error"})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(GetResponse{Key: key, Value: result})
}

func (s *Server) handleSet(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if key == "" {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "key is required"})
		return
	}

	var req SetRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "invalid request body"})
		return
	}

	if req.Value == "" {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "value is required"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	builder := s.client.B().Set().Key(key).Value(req.Value)
	if req.Expiration > 0 {
		// Expiration is in seconds
		builder.Ex(req.Expiration)
	}

	err := s.client.Do(ctx, builder.Build()).Error()
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "internal server error"})
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"status": "created", "key": key})
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if key == "" {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "key is required"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	result, err := s.client.Do(ctx, s.client.B().Del().Key(key).Build()).AsInt64()
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "internal server error"})
		return
	}

	if result == 0 {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "key not found"})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "deleted", "key": key})
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	pattern := r.URL.Query().Get("pattern")
	if pattern == "" {
		pattern = "*"
	}

	limitStr := r.URL.Query().Get("limit")
	limit := 100 // default limit
	if limitStr != "" {
		fmt.Sscanf(limitStr, "%d", &limit)
		if limit > 1000 || limit < 1 {
			limit = 100
		}
	}

	cursor := uint64(0)
	keys := []string{}

	for {
		result, err := s.client.Do(ctx, s.client.B().Scan().Cursor(cursor).Match(pattern).Count(uint64(limit)).Build()).AsScanEntry()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(ErrorResponse{Error: "internal server error"})
			return
		}

		keys = append(keys, result.Keys...)
		cursor = result.Cursor

		if cursor == 0 || len(keys) >= limit {
			break
		}
	}

	if len(keys) > limit {
		keys = keys[:limit]
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"keys":  keys,
		"count": len(keys),
	})
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	s.router.ServeHTTP(w, r)
}

func loadConfig() *Config {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	valkeyAddress := os.Getenv("VALKEY_ADDRESS")
	if valkeyAddress == "" {
		valkeyAddress = "localhost:6379"
	}

	valkeyPassword := os.Getenv("VALKEY_PASSWORD")
	authToken := os.Getenv("AUTH_TOKEN")

	return &Config{
		Port:           port,
		ValkeyAddress:  valkeyAddress,
		ValkeyPassword: valkeyPassword,
		AuthToken:      authToken,
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
		IdleTimeout:    120 * time.Second,
	}
}

func main() {
	config := loadConfig()

	// Initialize Valkey client
	clientOption := valkey.ClientOption{
		InitAddress: []string{config.ValkeyAddress},
	}
	
	// Add password if provided
	if config.ValkeyPassword != "" {
		clientOption.Password = config.ValkeyPassword
	}

	client, err := valkey.NewClient(clientOption)
	if err != nil {
		log.Fatalf("Failed to create Valkey client: %v", err)
	}
	defer client.Close()

	// Test connection
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := client.Do(ctx, client.B().Ping().Build()).ToString(); err != nil {
		log.Fatalf("Failed to connect to Valkey: %v", err)
	}

	log.Printf("Connected to Valkey at %s", config.ValkeyAddress)
	if config.ValkeyPassword != "" {
		log.Println("Valkey password authentication enabled")
	}
	if config.AuthToken != "" {
		log.Println("Token authentication enabled")
	} else {
		log.Println("Warning: No AUTH_TOKEN configured - API is unsecured")
	}

	// Create server
	server := NewServer(client, config.AuthToken)

	httpServer := &http.Server{
		Addr:         ":" + config.Port,
		Handler:      server,
		ReadTimeout:  config.ReadTimeout,
		WriteTimeout: config.WriteTimeout,
		IdleTimeout:  config.IdleTimeout,
	}

	// Graceful shutdown
	go func() {
		log.Printf("Server starting on port %s", config.Port)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")
	ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}

