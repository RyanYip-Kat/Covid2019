library(Seurat)
library(argparse)
library(monocle3)
library(stringr)

parser <- ArgumentParser(description='Process some tasks')
parser$add_argument("--outdir",
                    type="character",
                    default="output",
                    help="the path to save result")

args <- parser$parse_args()
dataset<-args$outdir
model.dir<-file.path(dataset,"model")
plot.dir<-file.path(dataset,"plot")
if(!dir.exists(model.dir)){
        dir.create(model.dir,recursive=TRUE)
}

if(!dir.exists(plot.dir)){
        dir.create(plot.dir,recursive=TRUE)
}



pcv1="/Data/zoc/result/PBMC/10X-count/10X-VDJ/human/5RNA/PCV-1-5RNA/outs"
pcv3="/Data/zoc/result/PBMC/10X-count/10X-VDJ/human/5RNA/PCV-3-RNA-5RNA/outs"

pcv1_counts=Read10X(file.path(pcv1,"filtered_feature_bc_matrix"))
pcv3_counts=Read10X(file.path(pcv3,"filtered_feature_bc_matrix"))

pcv1_cluster<-read.csv(file.path(pcv1,"analysis/clustering/graphclust/clusters.csv"))
barcode1<-str_replace_all(pcv1_cluster$Barcode,"-1","")
rownames(pcv1_cluster)=barcode1

pcv3_cluster<-read.csv(file.path(pcv3,"analysis/clustering/graphclust/clusters.csv"))
barcode3<-str_replace_all(pcv3_cluster$Barcode,"-1","")
rownames(pcv3_cluster)=barcode3

cluster1<-subset(pcv1_cluster,select=Cluster,Cluster%in%c(1,6))
cluster3<-subset(pcv3_cluster,select=Cluster,Cluster%in%c(7,13))
cluster1$Cluster<-paste("PCV1",cluster1$Cluster,sep="_")
cluster3$Cluster<-paste("PCV3",cluster3$Cluster,sep="_")

tcell_1=rownames(cluster1)
tcell_3=rownames(cluster3)

counts_t1<-pcv1_counts[,tcell_1]
counts_t3<-pcv3_counts[,tcell_3]

colnames(counts_t1)=paste("PCV-1",colnames(counts_t1),sep="_")
colnames(counts_t3)=paste("PCV-3",colnames(counts_t3),sep="_")
rownames(cluster1)=colnames(counts_t1)
rownames(cluster3)=colnames(counts_t3)

orig.Cluster<-rbind(cluster1,cluster3)
colnames(orig.Cluster)<-"orig.Cluster"

counts<-cbind(counts_t1,counts_t3)
print("### Create Seurat object")
object<-CreateSeuratObject(counts= counts,
                       assay = "RNA",
                       project ="scRNA",
                       names.delim="_",
                       min.cells=0, 
                       min.features=0)

object<-AddMetaData(object,metadata=orig.Cluster)
object[["percent.mt"]] <- PercentageFeatureSet(object,pattern = "^MT-")
object[["percent.rpl"]] <- PercentageFeatureSet(object,pattern = "^RPL")
object[["percent.rps"]] <- PercentageFeatureSet(object,pattern = "^RPS")
object <- FindVariableFeatures(object, selection.method = "vst",
                            nfeatures = 5000,verbose = FALSE)

genes<-rownames(object)
keep_genes<-genes[!str_detect(genes,"^MT-|^RPL|^RPS")]
counts<-GetAssayData(object,"counts")
print("#### cell meta data")
protocol<-unlist(lapply(colnames(counts),function(c){
                              protocol<-str_split(c,"_")[[1]]
                              return(protocol[1])}))

target<-unlist(lapply(colnames(counts),function(c){
                              protocol<-str_split(c,"-")[[1]]
                              return(protocol[1])}))

print(table(target))
pd<-data.frame("sample"=protocol,"time"=target)

rownames(pd)<-colnames(counts)
print("#### gene meta data")
fd <- data.frame(gene_short_name = row.names(counts), row.names = row.names(counts))
print("#### new cell data set")
cds<-new_cell_data_set(counts,cell_metadata=pd,gene_metadata=fd)

print("### preprocess ")
cds<-detect_genes(cds,min_expr=0.1)

######### new modify
#genes<-VariableFeatures(object)
cds<-cds[keep_genes,]
#########

cds <- preprocess_cds(cds,
                      num_dim = 50,
                      method="PCA",
                      norm_method="log")
                      #residual_model_formula_str="~Size_Factor+num_genes_expressed",
                      #alignment_group="sample")

jpeg(file.path(plot.dir,"pc_variance_explain.jpeg"),width=1024,height=1024)
plot_pc_variance_explained(cds)
dev.off()

print("### Align")
cds <- align_cds(cds,
                 preprocess_method="PCA",
                 alignment_k=20,
                 residual_model_formula_str="~Size_Factor+num_genes_expressed",
                 alignment_group = "time")

print("### reduce dimension")
cds <- reduce_dimension(cds,reduction_method="tSNE",preprocess_method="Aligned",cores=1)
cds <- reduce_dimension(cds,reduction_method="UMAP",preprocess_method="Aligned",cores=1)

print("### cluster")
cds<-cluster_cells(cds,
                   reduction_method="UMAP",
                   k=20,
                   cluster_method="leiden",
                   partition_qval=0.01)

cds<-cluster_cells(cds,
                   reduction_method="tSNE",
                   k=20,
                   cluster_method="leiden",
                   partition_qval=0.01)

print("### Find marker genes expressed by each cluster")
#marker_test_res <-top_markers(cds, cores=3)


print("### learn graph")
cds<-learn_graph(cds,
                 use_partition=TRUE,
                 close_loop=TRUE)

print("### Save monocle")
saveRDS(cds,file.path(model.dir,"monocle.rds"))

print(paste0("Size of counts after monocle3 selection [ ",nrow(counts),",",ncol(counts)," ]"))
protocol<-unlist(lapply(colnames(counts),function(c){
                              protocol<-str_split(c,"_")[[1]]
                              return(protocol[1])}))

target<-unlist(lapply(colnames(counts),function(c){
                              protocol<-str_split(c,"-")[[1]]
                              return(protocol[1])}))

object@meta.data$sample<-protocol
object@meta.data$time<-target

print("### Find Variable Features")
object <- FindVariableFeatures(object, selection.method = "vst",
                            nfeatures = 5000,verbose = FALSE)

print("### Normalize Data")
object<-NormalizeData(object,normalization.method = "LogNormalize",verbose = FALSE)

print("### Scale Data")
object<-ScaleData(object,features=keep_genes,model.use = "linear",
               vars.to.regress = c("nFeature_RNA"),verbose =FALSE)
#########################
print("### Create ReducedDim from monocle and add clusters")
tSNE_clusters<-clusters(cds,reduction_method="tSNE")
UMAP_clusters<-clusters(cds,reduction_method="UMAP")

tSNE_partitions<-partitions(cds,reduction_method="tSNE")
UMAP_partitions<-partitions(cds,reduction_method="UMAP")

monocle_meta<-data.frame("tSNE_clusters"=tSNE_clusters,
                         "UMAP_clusters"=UMAP_clusters,
                         "tSNE_partitions"=tSNE_partitions,
                         "UMAP_partitions"=UMAP_partitions,
                         row.names=names(tSNE_clusters))
print("### Add MetaData")
object<-AddMetaData(object,metadata=monocle_meta)

print("### Add reducedDims")
print("#### Add tSNE")
mat<-reducedDims(cds)[["tSNE"]]
colnames(mat)<-paste("tSNE_",1:ncol(mat),sep = "")
object[["tsne"]]<-CreateDimReducObject(embeddings =mat,
                                  key = "tSNE_",
                                  assay = DefaultAssay(object))
print("#### Add UMAP")
mat<-reducedDims(cds)[["UMAP"]]
colnames(mat)<-paste("UMAP_",1:ncol(mat),sep = "")
object[["umap"]]<-CreateDimReducObject(embeddings =mat,
                                  key = "UMAP_",
                                  assay = DefaultAssay(object))

print("#### Add PCA")
mat<-reducedDims(cds)[["PCA"]]
colnames(mat)<-paste("PCA_",1:ncol(mat),sep = "")
object[["pca"]]<-CreateDimReducObject(embeddings =mat,
                                  key = "PCA_",
                                  assay = DefaultAssay(object))

print("#### Add Aligned")
mat<-reducedDims(cds)[["Aligned"]]
colnames(mat)<-paste("Aligned_",1:ncol(mat),sep = "")
object[["aligned"]]<-CreateDimReducObject(embeddings =mat,
                                  key = "Aligned_",
                                  assay = DefaultAssay(object))

saveRDS(object,file.path(model.dir,"seurat.rds"))
print("### Difference Analysis and Find Markers")
print("### For UMAP Clusters")
Idents(object)<-object@meta.data$UMAP_clusters
UMAP_markers <- FindAllMarkers(object, only.pos = FALSE,
                          features = keep_genes,
                          test.use = "wilcox",
                          min.pct = 0.2,
                          logfc.threshold = 0.25,
                          pseudocount.use = 1 )



print("### Save")
#saveRDS(object,file.path(model.dir,"seurat.rds"))
saveRDS(UMAP_markers,file.path(model.dir,"UMAP_SeuratMarkers.rds"))




