package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	connString = "postgres://myuser:mypassword@localhost:5432/mydatabase"
	targetGB   = 2.0
)

func main() {
	ctx := context.Background()

	fmt.Println("🔍 Connecting to PostgreSQL...")
	pool, err := pgxpool.New(ctx, connString)
	if err != nil {
		log.Fatalf("❌ Unable to connect: %v\n", err)
	}
	defer pool.Close()

	// 1. Setup Tables
	fmt.Println("🏗️  Setting up database schema...")
	initSchema(pool)

	fmt.Println("🚀 Real-Time Simulation Started! Target: 2.0 GB")
	fmt.Println("📊 Target Distribution: Audit(50%) | Orders(40%) | Users(10%)")
	fmt.Println("-------------------------------------------")

	var wg sync.WaitGroup
	start := time.Now()

	// 2. Launch Workers with specific ratios
	wg.Add(6)

	// Heavy Load for Audit Logs (3 workers, no sleep)
	for i := 0; i < 3; i++ {
		go auditLogWorker(pool, &wg)
	}

	// Medium Load for Orders (2 workers, slight delay)
	for i := 0; i < 2; i++ {
		go orderWorker(pool, &wg)
	}

	// Light Load for Users (1 worker, longer delay)
	go userTrafficWorker(pool, &wg)

	// 3. Main Monitor Loop
	for {
		sizeGB := getDbSize(pool)
		elapsed := time.Since(start).Round(time.Second)

		fmt.Printf("\r[LIVE] Size: %.3f GB | Elapsed: %s | Progress: %.1f%%",
			sizeGB, elapsed, (sizeGB/targetGB)*100)

		if sizeGB >= targetGB {
			fmt.Printf("\n\n✅ Target of %.1f GB reached in %s!\n", targetGB, elapsed)
			break
		}
		time.Sleep(1 * time.Second)
	}
}

func initSchema(pool *pgxpool.Pool) {
	queries := []string{
		`CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, username TEXT, bio TEXT, created_at TIMESTAMP DEFAULT NOW())`,
		`CREATE TABLE IF NOT EXISTS orders (id SERIAL PRIMARY KEY, user_id INT, price DECIMAL, raw_data JSONB)`,
		`CREATE TABLE IF NOT EXISTS audit_logs (id SERIAL PRIMARY KEY, action TEXT, metadata TEXT, timestamp TIMESTAMP DEFAULT NOW())`,
	}
	for _, q := range queries {
		_, err := pool.Exec(context.Background(), q)
		if err != nil {
			log.Fatalf("❌ Schema Error: %v", err)
		}
	}
}

// Target: ~50% of storage. Uses large metadata string and no sleep.
func auditLogWorker(pool *pgxpool.Pool, wg *sync.WaitGroup) {
	defer wg.Done()
	// ~4KB of metadata per row
	heavyMetadata := strings.Repeat("SYSTEM_LOG_METADATA_EXTENDED_", 150)

	for {
		_, err := pool.Exec(context.Background(),
			"INSERT INTO audit_logs (action, metadata) VALUES ($1, $2)",
			"EVENT_TRACE", heavyMetadata)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
		}
	}
}

// Target: ~40% of storage. Uses JSON payload and 5ms delay.
func orderWorker(pool *pgxpool.Pool, wg *sync.WaitGroup) {
	defer wg.Done()
	// ~2KB of data per row
	orderPayload := strings.Repeat("PRODUCT_ORDER_BLOB_", 100)

	for {
		_, err := pool.Exec(context.Background(),
			"INSERT INTO orders (user_id, price, raw_data) VALUES ($1, $2, $3)",
			rand.Intn(10000), rand.Float64()*500, fmt.Sprintf(`{"details": "%s"}`, orderPayload))
		if err != nil {
			time.Sleep(100 * time.Millisecond)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// Target: ~10% of storage. Light row size and 50ms delay.
func userTrafficWorker(pool *pgxpool.Pool, wg *sync.WaitGroup) {
	defer wg.Done()
	bioData := strings.Repeat("USER_PROFILE_BIO_INFO_", 10)

	for {
		_, err := pool.Exec(context.Background(),
			"INSERT INTO users (username, bio) VALUES ($1, $2)",
			fmt.Sprintf("user_%d", rand.Intn(1000000)), bioData)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func getDbSize(pool *pgxpool.Pool) float64 {
	var bytes int64
	// Make sure to replace 'mydatabase' with your actual database name if different
	err := pool.QueryRow(context.Background(), "SELECT pg_database_size('mydatabase')").Scan(&bytes)
	if err != nil {
		return 0
	}
	return float64(bytes) / 1024 / 1024 / 1024
}
