output "address" {
  description = "Private DNS name of the database."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "connection_url" {
  description = "SQLAlchemy URL in the format the application reads from DATABASE_URL."
  sensitive   = true
  value = format(
    "postgresql+psycopg://%s:%s@%s:%d/%s?sslmode=require",
    var.username,
    random_password.master.result,
    aws_db_instance.this.address,
    aws_db_instance.this.port,
    var.database_name,
  )
}
